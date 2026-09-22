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
    * `"video"` - its soundtrack is transcribed when `ffmpeg` and a transcription route
      exist (`Pepe.Media.Video`), framed as quoted material, and the file is kept; without
      either, the agent is pointed at the file.
    * `"sticker"` - shown to a vision model as an image, so the agent can react to it the
      way a person would. Without vision there is nothing to say about a sticker, so it is
      neither downloaded nor answered.
    * anything else, and anything that could not be read: the file lands in the agent's
      workspace and the agent is told where it is. That is the safety net, not the way
      in - it costs a permission prompt and a wait, and comes out different every time.

  One message may carry several attachments (Discord allows ten). They are taken in the
  order sent, each resolved the way it would be alone; the caption goes with the first one
  that could be read, and the pieces reach the agent as one message.

  Every one of these is a stranger's file, so the turn it produces stays `untrusted:
  true` - `Pepe.Webhooks` already withdraws pre-approval for every inbound webhook
  message, media or not - and extracted document text is additionally framed with
  `Pepe.Security.ExternalContent`, the same marking `fetch_url` and `db_query` put
  around anything they bring in from outside.

  What the sender is told when something goes wrong is translated (`webhooks` domain) into
  the operator's language, like every other reply Pepe writes on its own.
  """

  use Gettext, backend: Pepe.Gettext

  require Logger

  alias Pepe.Agent.Workspace
  alias Pepe.Security.ExternalContent

  @typedoc """
  One attachment, as a provider's `parse/1` describes it.

    * `:kind` - `"audio"`, `"image"`, `"document"`, `"video"`, `"sticker"`; anything else
      is treated as a file the agent is merely pointed at.
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
  # a file that is "too big to send me" means the same thing on every channel. WhatsApp
  # (16MB for audio and video, 5MB for images) caps lower than this anyway, and Discord's own
  # upload limit has moved more than once; this is the backstop, not the channel's own limit
  # restated. A connection may raise or lower it (`max_attachment_mb`), because an operator
  # who takes 100MB documents on WhatsApp knows something this default does not.
  @default_max_bytes 20 * 1_048_576
  @max_configured_mb 100

  # How many attachments of one message are taken in. Discord's own limit is ten; the
  # rest of a longer list is not looked at, so a payload cannot buy unbounded downloads.
  @max_attachments 10

  # Enough of a label to be useful in a prompt, and not enough to be a payload.
  @max_name 120

  @doc "The default largest inbound attachment a webhook channel will take in, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @default_max_bytes

  @doc """
  The largest inbound attachment *this connection* takes in, in bytes: its
  `max_attachment_mb` (a whole number of megabytes, at most #{@max_configured_mb}) or the
  default. Anything that is not such a number is ignored, so a typo in the config can
  never switch the limit off.
  """
  @spec max_bytes(map()) :: pos_integer()
  def max_bytes(entry) when is_map(entry) do
    case configured_mb(entry) do
      mb when is_integer(mb) and mb > 0 and mb <= @max_configured_mb -> mb * 1_048_576
      _ -> @default_max_bytes
    end
  end

  defp configured_mb(entry) do
    value = get_in(entry, ["config", "max_attachment_mb"]) || entry["max_attachment_mb"]

    case value do
      n when is_integer(n) ->
        n

      text when is_binary(text) ->
        case Integer.parse(String.trim(text)) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Check a *declared* size against the cap, before spending a download on it. `:ok` for a
  size that fits and for anything that isn't a number (a provider whose payload doesn't
  say - the real check then happens on the bytes that arrive).
  """
  @spec within_cap(term()) :: :ok | {:error, :too_large}
  def within_cap(size), do: within_cap(size, @default_max_bytes)

  @spec within_cap(term(), pos_integer() | map()) :: :ok | {:error, :too_large}
  def within_cap(size, %{} = entry), do: within_cap(size, max_bytes(entry))
  def within_cap(size, cap) when is_integer(size) and size > cap, do: {:error, :too_large}
  def within_cap(_size, _cap), do: :ok

  @doc """
  Turn one parsed inbound message into the text the agent should actually be given.

  `{:ok, text, opts}` - `opts` carries `:images` for a turn the model should *see*.
  `:ignore` when there is nothing to answer: the fetch failed, or the audio had no
  speech in it. Either way the sender has already been told, through `mod.deliver/3`.

  A message with no `:media` passes straight through, unchanged. `:media` is one
  attachment or a list of them.
  """
  @spec resolve(module(), map(), map()) :: {:ok, String.t(), keyword()} | :ignore
  def resolve(mod, entry, message) do
    case attachments(entry, message) do
      [] -> passthrough(message)
      medias -> ingest_all(mod, entry, message, medias)
    end
  end

  # Nothing to take in. That is a plain text message, unless the message *was* only
  # attachments and every one was set aside (a sticker no model here can look at): there is
  # then no message left, and an empty turn would only make the agent say something to nobody.
  defp passthrough(message) do
    text = message |> Map.get(:text) |> to_string()
    set_aside? = message |> Map.get(:media) |> List.wrap() |> Enum.any?()

    if set_aside? and String.trim(text) == "", do: :ignore, else: {:ok, message.text, []}
  end

  # A sticker is only worth taking if something can look at it; deciding that here keeps
  # a download (and a file left in the workspace) from happening for nothing.
  defp attachments(entry, message) do
    message
    |> Map.get(:media)
    |> List.wrap()
    |> Enum.filter(&match?(%{ref: _}, &1))
    |> Enum.reject(&(kind(&1) == "sticker" and not vision_model?(entry)))
    |> Enum.take(@max_attachments)
  end

  defp ingest_all(mod, entry, message, medias) do
    caption = message |> Map.get(:text) |> to_string() |> String.trim()

    {parts, opts, _caption} =
      Enum.reduce(medias, {[], [], caption}, fn media, {parts, opts, caption} ->
        case ingest(mod, entry, message, media, caption, opts) do
          {:ok, text, more} -> {[text | parts], merge(opts, more), ""}
          :ignore -> {parts, opts, caption}
        end
      end)

    case Enum.reverse(parts) do
      [] -> :ignore
      parts -> {:ok, Enum.join(parts, "\n\n"), opts}
    end
  end

  # Images accumulate across attachments; anything else a later attachment adds replaces.
  defp merge(opts, more) do
    Enum.reduce(more, opts, fn
      {:images, images}, acc -> Keyword.update(acc, :images, images, &(&1 ++ images))
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp ingest(mod, entry, message, media, caption, opts) do
    cap = max_bytes(entry)

    with :ok <- within_cap(media[:size], cap),
         {:ok, bytes} <- fetch(mod, entry, media),
         :ok <- within_cap(byte_size(bytes), cap),
         {:ok, path} <- store(entry, media, bytes) do
      interpret(mod, entry, message, media, path, caption, opts)
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
  rescue
    # A provider that raises must cost the sender a sentence, not silence.
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:crashed, inspect(reason)}}
  end

  # Into the bound agent's own workspace, under `media/`, named by us: the sender's
  # filename contributes an extension and nothing else, so no name they choose can
  # decide where the file lands.
  defp store(entry, media, bytes) do
    dir = Path.join(workspace(entry), "media")
    name = "#{kind(media)}_#{System.unique_integer([:positive])}#{extension(media)}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, name), bytes) do
      Pepe.Webhooks.Media.Retention.prune(dir, name)
      {:ok, "media/#{name}"}
    end
  end

  ###
  ### what each kind becomes
  ###

  defp interpret(mod, entry, message, %{kind: "audio"}, path, caption, _opts) do
    case Pepe.Media.transcribe(abs_path(entry, path)) do
      # Silence, or audio with nothing said in it. The file was read; there was just
      # nothing in it, and answering an empty message only produces a confused reply.
      {:ok, ""} ->
        say(mod, entry, message.from, dgettext("webhooks", "I couldn't make out any speech in that."))
        :ignore

      {:ok, text} ->
        text = ExternalContent.sanitize(text)
        if Pepe.Media.echo?(), do: say(mod, entry, message.from, "📝 " <> text)
        {:ok, join(text, caption), []}

      :unavailable ->
        {:ok, prompt("audio", path, caption), []}
    end
  end

  defp interpret(_mod, entry, _message, %{kind: "document"} = media, path, caption, _opts) do
    case Pepe.Media.Document.extract(abs_path(entry, path)) do
      {:ok, text} -> {:ok, attached(entry, media, path, text, caption), []}
      :unavailable -> {:ok, prompt("document", path, caption), []}
    end
  end

  defp interpret(_mod, entry, _message, %{kind: "image"}, path, caption, opts) do
    case if(images_left?(opts), do: vision_image(entry, path), else: :none) do
      {:ok, image} -> {:ok, image_prompt(caption), [images: [image]]}
      :none -> {:ok, prompt("image", path, caption), []}
    end
  end

  # A sticker is a reaction, so it gets a reaction: shown to the model, with the plain
  # instruction not to narrate it. No caption to speak of - a sticker has none.
  defp interpret(_mod, entry, _message, %{kind: "sticker"}, path, _caption, opts) do
    case if(images_left?(opts), do: vision_image(entry, path), else: :none) do
      {:ok, image} -> {:ok, sticker_prompt(), [images: [image]]}
      :none -> :ignore
    end
  end

  defp interpret(_mod, entry, _message, %{kind: "video"} = media, path, caption, _opts) do
    case Pepe.Media.Video.transcribe(abs_path(entry, path)) do
      {:ok, text} when text != "" -> {:ok, video_prompt(entry, media, path, text, caption), []}
      _ -> {:ok, prompt("video", path, caption), []}
    end
  end

  defp interpret(_mod, _entry, _message, media, path, caption, _opts),
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

  # The soundtrack of a video is what somebody said near a camera, not an instruction to
  # this agent, so it is framed as quoted material like a document's text.
  defp video_prompt(entry, media, path, text, caption) do
    source = "#{entry["provider"]}:#{label(media, path)}"

    "The user sent a video, saved in your workspace at `#{path}`. What is said in its soundtrack:\n" <>
      ExternalContent.mark_untrusted(source, ExternalContent.sanitize(text)) <>
      "\n(You have only its soundtrack, not its pictures.)" <> caption_line(caption)
  end

  # Load the image only if the bound agent's model declares vision; `:none` falls back to
  # the path prompt (a text-only model, an oversized file, or an unsupported type - that
  # policy lives in Pepe.Media.Vision, not here).
  defp vision_image(entry, path) do
    if vision_model?(entry), do: Pepe.Media.Vision.load(abs_path(entry, path)), else: :none
  end

  # One turn carries at most `media.image.max_parts` images; the rest of a long album is
  # handed over as paths, the same fallback an oversized image gets.
  defp images_left?(opts), do: length(opts[:images] || []) < Pepe.Media.Vision.max_parts()

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

  defp sticker_prompt,
    do:
      "The user sent you this sticker. It is a reaction, not a question: answer it the way a " <>
        "person would, in a few words, and do not describe the picture unless they ask."

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
    do:
      dgettext(
        "webhooks",
        "That file is too big for me to take in here. Could you send a smaller version, or share it another way?"
      )

  defp friendly_error(:unsupported),
    do: dgettext("webhooks", "I can't pick up attachments on this channel yet. Could you send it as text?")

  defp friendly_error(_reason), do: dgettext("webhooks", "I couldn't download that file. Could you send it again?")

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
