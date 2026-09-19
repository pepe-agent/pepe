defmodule Pepe.ACP.Content do
  @moduledoc """
  What an editor puts in a `session/prompt`, turned into what one agent turn takes: the
  text, the images the model should *see*, and anything the person should be told.

  An ACP prompt is an array of typed content blocks, not a string. This module reads all
  five kinds and decides what each becomes:

    * `text` - itself.
    * `resource_link` - a pointer (`@name (uri)`) the agent can follow with its own tools,
      except when it names a file *inside the project the editor opened*: those are read
      here and inlined (text, an image for a vision model, a PDF or Office file as text),
      because an `@file` mention that costs the agent a tool call and a permission prompt
      before it can even start is a worse experience than the editor's own. Reading a file
      inside the project is exactly what `read_file` already allows without asking, so this
      widens nothing. A link to anything outside the project stays a pointer.
    * `image` - handed to the model as an actual image, when the agent's model has vision.
    * `audio` - transcribed (`Pepe.Media.transcribe/1`) and the transcript joins the prompt.
    * `resource` (embedded context) - a text resource is framed and included; a binary one
      is an image, a document read as text (`Pepe.Media.Document`), or text that happened to
      arrive base64-encoded.

  ## What is never done silently

  Anything that could not be used - a model with no vision, an oversized file, a format
  nobody here can read - becomes a **note** for the person *and* a marker line in the
  prompt, so neither the person nor the model is left believing the attachment was read.
  A block that is structurally wrong (no `data`, a type nobody defined) is an error, not
  a note: that is a client bug, and the editor should hear it.

  ## Trust

  Text that came out of a binary format (a `.docx`, a `.pdf`) is a stranger's file, so it
  is sanitized and framed with `Pepe.Security.ExternalContent` and the turn is reported as
  `untrusted?: true`, the same handling a document on Telegram or WhatsApp gets. A
  transcript is sanitized but *not* marked (that would break a spoken slash command), and
  plain text the editor itself sent - a selection, a project file - is sanitized and
  framed but not tainted: it is what the person is looking at, no different from typed
  text or a `read_file` result.

  Everything that touches the outside (transcription, document extraction, the image
  loader, the clock's temp dir) is injectable through `resolve/2`'s options, so the whole
  module is testable without a model, a network or a disk it does not own.
  """

  alias Pepe.LLM.Image
  alias Pepe.Media.Document
  alias Pepe.Media.Vision
  alias Pepe.Security.ExternalContent

  @known ~w(text resource_link image audio resource)

  @max_blocks 64
  @max_label 120
  @max_uri 500

  # A file is read only this far before it is cut to `Document.max_chars/0` characters, so a
  # huge log costs a bounded read, not the whole file.
  @max_read_bytes 400_000

  @office ~w(.docx .xlsx .pptx .pdf)
  @images ~w(.png .jpg .jpeg .gif .webp)

  @type t :: %{
          text: String.t(),
          images: [Image.t()],
          notes: [String.t()],
          untrusted?: boolean()
        }

  ###
  ### what this agent can take, for `initialize`
  ###

  @doc """
  The `promptCapabilities` this connection can honestly promise for `agent_name` (nil for
  the default agent): `image` only when its model has vision, `audio` only when a
  transcription route exists right now, `embeddedContext` always.
  """
  @spec capabilities(String.t() | nil) :: map()
  def capabilities(agent_name) do
    %{
      "image" => vision_model?(agent_name),
      "audio" => Pepe.Media.transcription_available?(),
      "embeddedContext" => true
    }
  end

  @doc "Whether the model bound to `agent_name` declares vision (`vision: true` on its connection)."
  @spec vision_model?(String.t() | nil) :: boolean()
  def vision_model?(agent_name) do
    with {:ok, agent} <- Pepe.Agent.resolve(agent_name),
         %Pepe.Config.Model{vision: true} <- Pepe.Config.model_for_agent(agent) do
      true
    else
      _ -> false
    end
  end

  @doc "How a note for the person is worded when it is written into the reply stream."
  @spec note_text(String.t()) :: String.t()
  def note_text(note), do: "Note: #{note}\n\n"

  ###
  ### resolve
  ###

  @doc """
  Resolve a `session/prompt` block array. Options:

    * `:vision?` - the bound model can see images (default `false`).
    * `:cwd` - the project the editor opened; the only place a `resource_link` is read from.
    * `:transcribe`, `:extract`, `:load_image`, `:echo?` - the outside world, as functions
      (defaults: `Pepe.Media.transcribe/1`, `Pepe.Media.Document.extract/1`,
      `Pepe.Media.Vision.load/1`, `Pepe.Media.echo?/0`).
    * `:tmp_dir`, `:max_bytes`, `:image_max_bytes`, `:max_parts` - limits and scratch space.
  """
  @spec resolve(term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def resolve(blocks, opts \\ [])

  def resolve(blocks, opts) when is_list(blocks) and length(blocks) <= @max_blocks do
    with :ok <- validate(blocks) do
      ctx = context(opts)
      acc = Enum.reduce(blocks, empty(), fn block, acc -> apply_effects(effects(block, ctx), acc, ctx) end)

      {:ok,
       %{
         text: acc.parts |> Enum.reverse() |> Enum.join("\n"),
         images: Enum.reverse(acc.images),
         notes: Enum.reverse(acc.notes),
         untrusted?: acc.untrusted?
       }}
    end
  end

  def resolve(blocks, _opts) when is_list(blocks),
    do: {:error, "`prompt` has too many content blocks (the limit is #{@max_blocks})"}

  def resolve(_other, _opts), do: {:error, "`prompt` must be an array of content blocks"}

  defp context(opts) do
    %{
      vision?: Keyword.get(opts, :vision?, false),
      cwd: opts[:cwd],
      transcribe: Keyword.get(opts, :transcribe, &Pepe.Media.transcribe/1),
      extract: Keyword.get(opts, :extract, &Document.extract/1),
      load_image: Keyword.get(opts, :load_image, &Vision.load/1),
      echo?: Keyword.get(opts, :echo?, &Pepe.Media.echo?/0),
      tmp_dir: Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0),
      max_bytes: Keyword.get_lazy(opts, :max_bytes, &Pepe.Webhooks.Media.max_bytes/0),
      image_max_bytes: Keyword.get_lazy(opts, :image_max_bytes, &Vision.max_bytes/0),
      max_parts: Keyword.get_lazy(opts, :max_parts, &Vision.max_parts/0)
    }
  end

  defp empty, do: %{parts: [], images: [], notes: [], untrusted?: false}

  ###
  ### validation: a structurally wrong block is the client's bug
  ###

  defp validate(blocks) do
    Enum.find_value(blocks, :ok, fn block ->
      case check(block) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp check(%{"type" => "text", "text" => text}) when is_binary(text), do: :ok
  defp check(%{"type" => "resource_link", "uri" => uri}) when is_binary(uri), do: :ok
  defp check(%{"type" => "image", "data" => data}) when is_binary(data), do: :ok
  defp check(%{"type" => "audio", "data" => data}) when is_binary(data), do: :ok
  defp check(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text), do: :ok
  defp check(%{"type" => "resource", "resource" => %{"blob" => blob}}) when is_binary(blob), do: :ok

  defp check(%{"type" => type}) when type in @known,
    do: {:error, "a `#{type}` content block is missing the field that carries its content"}

  defp check(%{"type" => type}) when is_binary(type),
    do: {:error, "this agent does not accept `#{type}` content blocks (see the prompt capabilities it reported in `initialize`)"}

  defp check(_other), do: {:error, "every entry in `prompt` must be a content block with a `type`"}

  ###
  ### effects: what one block contributes
  ###

  # A block never touches the accumulator itself; it returns a list of effects, which keeps
  # each kind small and lets the image-count cap live in exactly one place.
  #
  #   {:text, s}             a line of the prompt
  #   {:image, image, label} an image for the model to see
  #   {:note, s}             something to tell the person
  #   :taint                 this turn now carries a stranger's text
  defp apply_effects(effects, acc, ctx), do: Enum.reduce(effects, acc, &apply_effect(&1, &2, ctx))

  defp apply_effect({:text, ""}, acc, _ctx), do: acc
  defp apply_effect({:text, text}, acc, _ctx), do: %{acc | parts: [text | acc.parts]}
  defp apply_effect({:note, note}, acc, _ctx), do: %{acc | notes: [note | acc.notes]}
  defp apply_effect(:taint, acc, _ctx), do: %{acc | untrusted?: true}

  defp apply_effect({:image, image, label}, acc, ctx) do
    if length(acc.images) < ctx.max_parts do
      %{acc | images: [image | acc.images], parts: ["[Attached image: #{label}]" | acc.parts]}
    else
      apply_effects(refused("image", label, "a turn can carry at most #{ctx.max_parts} images"), acc, ctx)
    end
  end

  defp effects(%{"type" => "text", "text" => text}, _ctx), do: [{:text, text}]

  defp effects(%{"type" => "resource_link"} = block, ctx), do: link_effects(block, ctx)

  defp effects(%{"type" => "image", "data" => data} = block, ctx) do
    label = image_label(block)

    case decode(data, ctx.image_max_bytes) do
      {:ok, bytes} -> image_effects(bytes, label, ctx)
      {:error, reason} -> refused("image", label, reason_text(reason, ctx.image_max_bytes))
    end
  end

  defp effects(%{"type" => "audio", "data" => data} = block, ctx) do
    with {:ok, bytes} <- decode(data, ctx.max_bytes),
         {:ok, text} <- transcribe(bytes, block["mimeType"], ctx) do
      transcript_effects(text, ctx)
    else
      {:error, reason} -> refused("audio", "audio", reason_text(reason, ctx.max_bytes))
    end
  end

  defp effects(%{"type" => "resource", "resource" => %{"text" => text} = res}, _ctx) do
    uri = clean_uri(res["uri"])
    plain_effects(label(nil, nil, uri), uri, text, nil)
  end

  defp effects(%{"type" => "resource", "resource" => %{"blob" => blob} = res}, ctx) do
    uri = clean_uri(res["uri"])
    label = label(nil, nil, uri)

    case decode(blob, ctx.max_bytes) do
      {:ok, bytes} -> blob_effects(bytes, res["mimeType"], uri, label, ctx)
      {:error, reason} -> refused("file", label, reason_text(reason, ctx.max_bytes))
    end
  end

  ###
  ### images
  ###

  defp image_effects(_bytes, label, %{vision?: false}),
    do: refused("image", label, "the model this agent uses can't see images")

  defp image_effects(bytes, label, ctx) do
    with :ok <- within(bytes, ctx.image_max_bytes),
         {:ok, image} <- Image.from_bytes(bytes) do
      [{:image, image, label}]
    else
      {:error, reason} -> refused("image", label, reason_text(reason, ctx.image_max_bytes))
    end
  end

  defp image_label(block), do: label(nil, nil, clean_uri(block["uri"]), "image")

  ###
  ### audio
  ###

  defp transcribe(bytes, mime, ctx) do
    path = Path.join(ctx.tmp_dir, "pepe_acp_audio_#{System.unique_integer([:positive])}#{audio_ext(bytes, mime)}")

    try do
      with :ok <- File.write(path, bytes) do
        case ctx.transcribe.(path) do
          {:ok, text} -> {:ok, text}
          :unavailable -> {:error, :no_transcription}
        end
      end
    after
      File.rm(path)
    end
  end

  defp transcript_effects("", _ctx), do: refused("audio", "audio", "no speech could be made out in it")

  defp transcript_effects(text, ctx) do
    text = ExternalContent.sanitize(text)
    echo = if ctx.echo?.(), do: [{:note, "Transcript of the audio: " <> text}], else: []
    [{:text, text} | echo]
  end

  # A provider reads the audio format off the file's extension, so it has to be right: from
  # the bytes' own header first (a declared type is a claim, and `MIME` lists `.oga` before
  # `.ogg`), from the declared type when the header is not one we know.
  defp audio_ext(bytes, mime) do
    case sniff_audio(bytes) do
      "" -> mime_ext(mime)
      ext -> ext
    end
  end

  defp sniff_audio(<<"OggS", _::binary>>), do: ".ogg"
  defp sniff_audio(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: ".wav"
  defp sniff_audio(<<"fLaC", _::binary>>), do: ".flac"
  defp sniff_audio(<<"ID3", _::binary>>), do: ".mp3"
  defp sniff_audio(<<0xFF, b, _::binary>>) when b in [0xFB, 0xF3, 0xF2], do: ".mp3"
  defp sniff_audio(<<_::binary-size(4), "ftyp", _::binary>>), do: ".m4a"
  defp sniff_audio(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: ".webm"
  defp sniff_audio(_bytes), do: ""

  ###
  ### embedded binary resources
  ###

  defp blob_effects(bytes, mime, uri, label, ctx) do
    ext = resource_ext(uri, mime)

    cond do
      String.starts_with?(mime_main(mime), "image/") -> image_effects(bytes, label, ctx)
      ext in @office -> office_blob(bytes, ext, uri, label, ctx)
      text?(bytes) -> plain_effects(label, uri, bytes, nil)
      true -> refused("file", label, "this kind of file (#{mime_main(mime) |> blank_to("unknown type")}) can't be read here")
    end
  end

  defp office_blob(bytes, ext, uri, label, ctx) do
    path = Path.join(ctx.tmp_dir, "pepe_acp_resource_#{System.unique_integer([:positive])}#{ext}")

    try do
      case File.write(path, bytes) do
        :ok -> office_result(ctx.extract.(path), uri, label)
        {:error, _} -> refused("file", label, "it could not be written out to be read")
      end
    after
      File.rm(path)
    end
  end

  defp office_result({:ok, text}, uri, label), do: office_effects(label, uri, text, nil)
  defp office_result(:unavailable, _uri, label), do: refused("file", label, "its text could not be extracted")

  ###
  ### resource links
  ###

  defp link_effects(block, ctx) do
    uri = clean_uri(block["uri"])
    label = label(block["title"], block["name"], uri)

    case local_file(uri, ctx.cwd) do
      {:ok, path} -> file_effects(path, uri, label, block, ctx)
      :error -> [{:text, pointer(block, uri)}]
    end
  end

  # `@name (uri)`: the way a person would type it, with the URI intact so the agent can act
  # on it.
  defp pointer(block, uri) do
    case label(nil, block["name"], "", "") do
      "" -> "@#{uri}"
      name -> "@#{name} (#{uri})"
    end
  end

  defp file_effects(path, uri, label, block, ctx) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in @images -> local_image(path, label, ctx)
      ext in @office -> local_office(path, uri, label, ctx)
      true -> local_text(path, uri, label, block, ctx)
    end
  end

  defp local_image(_path, label, %{vision?: false}),
    do: refused("image", label, "the model this agent uses can't see images")

  defp local_image(path, label, ctx) do
    case ctx.load_image.(path) do
      {:ok, image} -> [{:image, image, label}]
      :none -> refused("image", label, "it is not a PNG, JPEG, GIF or WebP image within the #{mb(ctx.image_max_bytes)} limit")
    end
  end

  defp local_office(path, uri, label, ctx) do
    with {:ok, %File.Stat{size: size}} when size <= ctx.max_bytes <- File.stat(path),
         {:ok, text} <- ctx.extract.(path) do
      office_effects(label, uri, text, nil)
    else
      {:ok, %File.Stat{}} -> refused("file", label, "it is larger than the #{mb(ctx.max_bytes)} limit")
      _ -> refused("file", label, "its text could not be extracted")
    end
  end

  defp local_text(path, uri, label, block, _ctx) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, head} <- read_head(path),
         true <- text?(head) do
      plain_effects(label, uri, head, if(size > @max_read_bytes, do: size))
    else
      # Binary, unreadable, or vanished: what is left is the pointer, and the agent's own
      # tools decide what to do with it.
      _ -> [{:text, pointer(block, uri)}]
    end
  end

  defp read_head(path) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, @max_read_bytes) do
        data when is_binary(data) -> data
        _ -> ""
      end
    end)
  end

  # Only a `file:` URI (or a bare absolute path) that resolves to a regular file *inside* the
  # project the editor opened is ever read. Anything else stays a pointer.
  defp local_file(_uri, nil), do: :error

  defp local_file(uri, cwd) do
    with {:ok, raw} <- file_path(uri),
         path = Path.expand(raw),
         root = Path.expand(cwd),
         true <- String.starts_with?(path <> "/", root <> "/"),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp file_path(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", host: host, path: path} when host in [nil, "", "localhost"] and is_binary(path) ->
        path |> safe_decode() |> windows_free()

      %URI{scheme: nil} ->
        if Path.type(uri) == :absolute, do: {:ok, uri}, else: :error

      _ ->
        :error
    end
  end

  # `file:///C:/x` is a Windows drive, which is not a path this machine can open.
  defp windows_free(<<"/", drive, ":", _::binary>>) when drive in ?A..?Z or drive in ?a..?z, do: :error
  defp windows_free(path), do: {:ok, path}

  # A malformed percent-escape raises; a client's bad URI is a pointer, not a crash.
  defp safe_decode(path) do
    URI.decode(path)
  rescue
    ArgumentError -> path
  end

  ###
  ### framing text
  ###

  # Text the editor sent itself, or a project file: sanitized and framed, not tainted.
  defp plain_effects(label, uri, body, total_bytes) do
    {shown, note} = cut(body, total_bytes)
    [{:text, frame(label, uri, ExternalContent.sanitize(shown), note)}]
  end

  # Text out of a binary format is a stranger's: marked, and the turn is tainted.
  defp office_effects(label, uri, text, total_bytes) do
    {shown, note} = cut(text, total_bytes)
    marked = ExternalContent.mark_untrusted("acp:" <> label, ExternalContent.sanitize(shown))
    [{:text, frame(label, uri, marked, note)}, :taint]
  end

  defp frame(label, uri, body, note) do
    [
      "[Attached file: #{label}]",
      if(uri == "", do: nil, else: "URI: #{uri}"),
      "",
      body,
      if(note, do: "[#{note}]"),
      "[End of attached file]"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp cut(text, size) do
    text = valid_prefix(text)
    max = Document.max_chars()
    shown = String.slice(text, 0, max)

    if String.length(text) > max or size do
      {shown, "Truncated: showing the first #{String.length(shown)} characters#{of_file(size)}."}
    else
      {text, nil}
    end
  end

  defp of_file(nil), do: ""
  defp of_file(size), do: " of a #{size}-byte file"

  # A read cut at a byte boundary can end in half a character.
  defp valid_prefix(text) do
    Enum.find_value(0..3, "", fn drop ->
      size = byte_size(text) - drop
      size >= 0 && String.valid?(binary_part(text, 0, size)) && binary_part(text, 0, size)
    end)
  end

  ###
  ### small helpers
  ###

  # Not an image, not a document: is it text that simply arrived as bytes? Binary files
  # contain NULs or fail UTF-8; source code and logs do not.
  defp text?(bytes) do
    not String.contains?(bytes, <<0>>) and
      (String.valid?(bytes) or byte_size(valid_prefix(bytes)) >= byte_size(bytes) - 3)
  end

  defp decode(data, cap) do
    data = String.replace(data, ~r/^data:[^,]*;base64,/i, "")

    # The encoded size is checked before anything is decoded, so a huge payload costs a
    # comparison, not an allocation.
    if byte_size(data) > div(cap * 4, 3) + 16, do: {:error, :too_large}, else: decode_checked(data, cap)
  end

  defp decode_checked(data, cap) do
    case Base.decode64(data, ignore: :whitespace, padding: false) do
      {:ok, bytes} when byte_size(bytes) > cap -> {:error, :too_large}
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :bad_base64}
    end
  end

  defp within(bytes, cap) when byte_size(bytes) > cap, do: {:error, :too_large}
  defp within(_bytes, _cap), do: :ok

  defp refused(kind, label, why) do
    subject = if label in [nil, "", kind], do: "The attached #{kind}", else: "The attached #{kind} (#{label})"
    sentence = "#{subject} was not included: #{why}."
    [{:text, "[#{sentence}]"}, {:note, sentence}]
  end

  defp reason_text(:too_large, cap), do: "it is larger than the #{mb(cap)} limit"
  defp reason_text(:bad_base64, _cap), do: "its data is not valid base64"
  defp reason_text(:unsupported_image_type, _cap), do: "only PNG, JPEG, GIF and WebP images are supported"
  defp reason_text(:no_transcription, _cap), do: "no transcription route is configured (see `media.audio`)"
  defp reason_text(other, _cap), do: "it could not be read (#{inspect(other)})"

  defp mb(bytes) when rem(bytes, 1_048_576) == 0, do: "#{div(bytes, 1_048_576)} MB"
  defp mb(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  # A name written by a stranger, made safe to sit in a prompt line: no control characters,
  # no chat-template tokens, bounded.
  defp label(title, name, uri, fallback \\ "file") do
    picked = Enum.find_value([title, name, Path.basename(uri)], &usable_name/1) || fallback

    picked
    |> ExternalContent.sanitize()
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.slice(0, @max_label)
  end

  defp usable_name(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp usable_name(_other), do: nil

  defp clean_uri(uri) when is_binary(uri) do
    uri |> String.replace(~r/[[:cntrl:]]+/u, " ") |> String.slice(0, @max_uri)
  end

  defp clean_uri(_other), do: ""

  defp mime_main(mime) when is_binary(mime), do: mime |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  defp mime_main(_mime), do: ""

  defp mime_ext(mime) do
    case mime |> mime_main() |> MIME.extensions() do
      [ext | _] -> "." <> ext
      [] -> ""
    end
  end

  # The URI's own extension names the kind best; the MIME type is the fallback.
  defp resource_ext(uri, mime) do
    case uri |> Path.extname() |> String.downcase() do
      "" -> mime_ext(mime)
      ext -> ext
    end
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end
