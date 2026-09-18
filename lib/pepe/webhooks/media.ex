defmodule Pepe.Webhooks.Media do
  @moduledoc """
  Inbound attachments on a webhook channel, resolved to text before the agent runs.

  This is the same door the Telegram gateway already puts a voice note through
  (`Pepe.Media`, `Pepe.Media.Document`, `Pepe.Media.Vision`), reached from the other
  side. WhatsApp and Discord hand over a provider-specific handle rather than a
  Telegram `file_id`, so the download is delegated back to the provider
  (`c:Pepe.Webhooks.Provider.fetch_media/2`) and everything after it is shared.

  Doing it here, and not inside the turn, buys the thing that cannot be bought later:
  **routing sees the words**. A `/new` said out loud, or a question asked in a voice
  note, reaches `Pepe.Webhooks`' command dispatch exactly as a typed one would. Wait
  until the agent is running and that decision has already been made without them.

  What each kind becomes:

    * `"audio"` - transcribed (`Pepe.Media.transcribe/1`); the transcript *is* the
      message, with the caption (if any) after it.
    * `"document"` - extracted (`Pepe.Media.Document.extract/1`) and attached to the
      caption, framed as quoted material rather than as instructions.
    * `"image"` - handed to the model as an actual image, when the bound agent's model
      has eyes; otherwise the path, like anything else.
    * anything else, and anything that could not be read: the file lands in the agent's
      workspace and the agent is told where it is. That is the safety net, not the way
      in - it costs a permission prompt and a wait, and comes out different every time.

  Every one of these is a stranger's file, so the turn it produces stays `untrusted:
  true` - `Pepe.Webhooks` already withdraws pre-approval for every inbound webhook
  message, media or not - and extracted document text is additionally framed with
  `Pepe.Security.ExternalContent`, the same marking `fetch_url` and `db_query` put
  around anything they bring in from outside.
  """

  require Logger

  alias Pepe.Agent.Workspace
  alias Pepe.Security.ExternalContent

  @typedoc """
  One attachment, as a provider's `parse/1` describes it.

    * `:kind` - `"audio"`, `"image"`, `"document"`, `"video"`; anything else is treated
      as a file the agent is merely pointed at.
    * `:ref` - the provider's own handle for the bytes (a WhatsApp media id, a Discord
      CDN url); opaque here, and only ever read back by the provider that wrote it.
    * `:filename` / `:mime` / `:size` - whatever the payload happened to carry. All
      three are written by the sender, so all three are treated as claims: the size is
      a cheap pre-check (never the only one), and the filename is used for its
      extension and as a label, never as a path.
  """
  @type t :: %{
          required(:kind) => String.t(),
          required(:ref) => term(),
          optional(:filename) => String.t() | nil,
          optional(:mime) => String.t() | nil,
          optional(:size) => non_neg_integer() | nil
        }

  # A ceiling on what one inbound message may push into the agent's workspace. Matches
  # what the Telegram path effectively allows (the Bot API refuses over 20MB itself), so
  # a file that is "too big to send me" means the same thing on every channel. Both
  # WhatsApp (16MB) and Discord (10MB unboosted) cap lower than this anyway; this is the
  # backstop for a provider that doesn't, not the channel's own limit restated.
  @max_bytes 20 * 1_048_576

  # Enough of a label to be useful in a prompt, and not enough to be a payload.
  @max_name 120

  @doc "The largest inbound attachment a webhook channel will take in, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Check a *declared* size against the cap, before spending a download on it. `:ok` for a
  size that fits and for anything that isn't a number (a provider whose payload doesn't
  say - the real check then happens on the bytes that arrive).
  """
  @spec within_cap(term()) :: :ok | {:error, :too_large}
  def within_cap(size) when is_integer(size) and size > @max_bytes, do: {:error, :too_large}
  def within_cap(_size), do: :ok

  @doc """
  Turn one parsed inbound message into the text the agent should actually be given.

  `{:ok, text, opts}` - `opts` carries `:images` for a turn the model should *see*.
  `:ignore` when there is nothing to answer: the fetch failed, or the audio had no
  speech in it. Either way the sender has already been told, through `mod.deliver/3`.

  A message with no `:media` passes straight through, unchanged.
  """
  @spec resolve(module(), map(), map()) :: {:ok, String.t(), keyword()} | :ignore
  def resolve(mod, entry, message) do
    case Map.get(message, :media) do
      %{ref: _} = media -> ingest(mod, entry, message, media)
      _ -> {:ok, message.text, []}
    end
  end

  defp ingest(mod, entry, message, media) do
    caption = message |> Map.get(:text) |> to_string() |> String.trim()

    with :ok <- within_cap(media[:size]),
         {:ok, bytes} <- fetch(mod, entry, media),
         :ok <- within_cap(byte_size(bytes)),
         {:ok, path} <- store(entry, media, bytes) do
      interpret(mod, entry, message, media, path, caption)
    else
      {:error, reason} ->
        Logger.warning("[webhooks] #{entry["slug"]}: inbound #{kind(media)} failed: #{inspect(reason)}")
        say(mod, entry, message.from, friendly_error(reason))
        :ignore
    end
  end

  # The bytes are the provider's business: only it knows whether its handle is a media id
  # to look up, a signed CDN url to GET, or something else again. A provider that hasn't
  # implemented it says so out loud rather than silently dropping the attachment.
  defp fetch(mod, entry, media) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_media, 2) do
      case mod.fetch_media(entry, media) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 -> {:ok, bytes}
        {:ok, _empty} -> {:error, :empty}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_return, other}}
      end
    else
      {:error, :unsupported}
    end
  end

  # Into the bound agent's own workspace, under `media/`, named by us: the sender's
  # filename contributes an extension and nothing else, so no name they choose can
  # decide where the file lands.
  defp store(entry, media, bytes) do
    dir = Path.join(workspace(entry), "media")
    name = "#{kind(media)}_#{System.unique_integer([:positive])}#{extension(media)}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, name), bytes) do
      {:ok, "media/#{name}"}
    end
  end

  ###
  ### what each kind becomes
  ###

  defp interpret(mod, entry, message, %{kind: "audio"}, path, caption) do
    case Pepe.Media.transcribe(abs_path(entry, path)) do
      # Silence, or audio with nothing said in it. The file was read; there was just
      # nothing in it, and answering an empty message only produces a confused reply.
      {:ok, ""} ->
        say(mod, entry, message.from, "I couldn't make out any speech in that.")
        :ignore

      {:ok, text} ->
        text = ExternalContent.sanitize(text)
        if Pepe.Media.echo?(), do: say(mod, entry, message.from, "📝 " <> text)
        {:ok, join(text, caption), []}

      :unavailable ->
        {:ok, prompt("audio", path, caption), []}
    end
  end

  defp interpret(_mod, entry, _message, %{kind: "document"} = media, path, caption) do
    case Pepe.Media.Document.extract(abs_path(entry, path)) do
      {:ok, text} -> {:ok, attached(entry, media, path, text, caption), []}
      :unavailable -> {:ok, prompt("document", path, caption), []}
    end
  end

  defp interpret(_mod, entry, _message, %{kind: "image"}, path, caption) do
    case vision_image(entry, path) do
      {:ok, image} -> {:ok, image_prompt(caption), [images: [image]]}
      :none -> {:ok, prompt("image", path, caption), []}
    end
  end

  defp interpret(_mod, _entry, _message, media, path, caption),
    do: {:ok, prompt(kind(media), path, caption), []}

  # A document is not the message, it is what came *with* the message: the caption is the
  # instruction ("summarise this"), the file is the material, and they arrive as one thing
  # so the agent answers about the content instead of first having to go and find it.
  defp attached(entry, media, path, text, caption) do
    name = label(media, path)
    source = "#{entry["provider"]}:#{name}"
    lead = if caption == "", do: "", else: caption <> "\n\n"

    lead <>
      ExternalContent.mark_untrusted(source, ExternalContent.sanitize(text)) <>
      "\n(The file itself is in your workspace at `#{path}`. Long documents are handed over " <>
      "only in part, so read it there if you need more of it.)"
  end

  # Load the image only if the bound agent's model declares vision; `:none` falls back to
  # the path prompt (a text-only model, an oversized file, or an unsupported type - that
  # policy lives in Pepe.Media.Vision, not here).
  defp vision_image(entry, path) do
    if vision_model?(entry), do: Pepe.Media.Vision.load(abs_path(entry, path)), else: :none
  end

  defp vision_model?(entry) do
    with %Pepe.Config.Agent{} = agent <- Pepe.Config.get_agent(entry["agent"]),
         %Pepe.Config.Model{vision: true} <- Pepe.Config.model_for_agent(agent) do
      true
    else
      _ -> false
    end
  end

  ###
  ### prompts (agent-facing, English; the agent replies in the user's own language)
  ###

  defp image_prompt(""), do: "The user sent you this image. Look at it and respond to what they want."
  defp image_prompt(caption), do: "The user sent you this image." <> caption_line(caption)

  defp prompt("audio", path, caption),
    do:
      "The user sent an audio message, saved in your workspace at `#{path}`." <>
        transcription_hint() <>
        " Once you have the text, respond to what they actually said." <>
        caption_line(caption)

  defp prompt("image", path, caption),
    do:
      "The user sent an image, saved at `#{path}`. Look at it and respond to what they want." <>
        caption_line(caption)

  defp prompt("document", path, caption),
    do:
      "The user sent a file, saved at `#{path}`. Inspect it and help with whatever they need." <>
        caption_line(caption)

  defp prompt(kind, path, caption),
    do:
      "The user sent a #{kind}, saved in your workspace at `#{path}`. " <>
        "Inspect it and help with whatever they need." <> caption_line(caption)

  # Cheapest route first, and no install playbook: a webhook channel is usually a
  # customer-facing agent with no shell at all, so telling it to go install a transcriber
  # is advice it cannot take. Configuring `media.audio` is the fix, and this says so.
  defp transcription_hint do
    " No transcription route is configured here, so you have to read it yourself: if a " <>
      "configured model connection's provider exposes an OpenAI-compatible " <>
      "`/audio/transcriptions` endpoint, POST the file there and use the text. Otherwise " <>
      "use a transcriber already on this machine (`whisper-cli`), if you have a shell at " <>
      "all. If you have neither, say so plainly rather than guessing at the contents."
  end

  defp caption_line(""), do: ""
  defp caption_line(caption), do: "\n\nTheir caption: #{caption}"

  defp join(text, ""), do: text
  defp join(text, caption), do: text <> "\n\n" <> caption

  ###
  ### what the sender is told when it doesn't work
  ###

  defp friendly_error(:too_large),
    do: "That file is too big for me to take in here. Could you send a smaller version, or share it another way?"

  defp friendly_error(:unsupported),
    do: "I can't pick up attachments on this channel yet. Could you send it as text?"

  defp friendly_error(_reason), do: "I couldn't download that file. Could you send it again?"

  # A reply that fails to send must not take the ingest down with it: the message is
  # already lost, and crashing here only loses the log line explaining why.
  defp say(mod, entry, to, text) do
    mod.deliver(entry, to, text)
  rescue
    e -> Logger.warning("[webhooks] #{entry["slug"]}: could not reply about media: #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("[webhooks] #{entry["slug"]}: could not reply about media: #{inspect(reason)}")
  end

  ###
  ### naming
  ###

  defp kind(media) do
    case media[:kind] do
      k when is_binary(k) and k != "" -> k
      _ -> "file"
    end
  end

  # The sender's own name for the file, when it is one: `report-q3.pdf` tells the agent
  # (and the human reading the reply) what was actually read. Stripped of anything that
  # could forge a line of its own in the prompt it gets interpolated into.
  defp label(media, path) do
    case media[:filename] do
      name when is_binary(name) and name != "" ->
        name
        |> Path.basename()
        |> ExternalContent.sanitize()
        |> String.replace(~r/[[:cntrl:]]+/u, " ")
        |> String.slice(0, @max_name)

      _ ->
        Path.basename(path)
    end
  end

  # The extension matters and is not decoration: a transcription provider reads the audio
  # format off it, and `Pepe.Media.Document` dispatches on it. Taken from the sender's
  # filename when it looks like an extension and nothing else, from the declared MIME type
  # otherwise.
  defp extension(media) do
    case media[:filename] do
      name when is_binary(name) -> from_name(Path.extname(name), media[:mime])
      _ -> from_mime(media[:mime])
    end
  end

  defp from_name(ext, mime) do
    if Regex.match?(~r/^\.[A-Za-z0-9]{1,8}$/, ext), do: String.downcase(ext), else: from_mime(mime)
  end

  # `audio/ogg; codecs=opus` is the shape WhatsApp sends a voice note as, so the
  # parameters come off before the type is looked up.
  defp from_mime(mime) when is_binary(mime) do
    case mime |> String.split(";") |> hd() |> String.trim() |> String.downcase() |> MIME.extensions() do
      [ext | _] -> "." <> ext
      [] -> ""
    end
  end

  defp from_mime(_mime), do: ""

  defp workspace(entry), do: Workspace.dir(entry["agent"])
  defp abs_path(entry, path), do: Path.join(workspace(entry), path)
end
