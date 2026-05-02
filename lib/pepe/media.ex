defmodule Pepe.Media do
  @moduledoc """
  Turns an inbound attachment into text, before the agent runs.

  A voice note is not a task, it is a message. Handing the raw file to the agent and
  letting it work out how to listen turns every voice message into a small research
  project: slow, different each time, and it spends a permission prompt on the mere act
  of reading the inbox. So media is resolved to text at the door, and what reaches the
  session is an ordinary message.

  Doing it here rather than inside the turn buys something that cannot be bought later:
  **routing sees the words**. A slash command or an @mention spoken out loud arrives as
  text, so it reaches the agent exactly as if it had been typed. Wait until the agent is
  already running and that decision has been made without the words.

  Three routes, tried in order, any of which may be missing:

    1. `media.audio.model` in the config: a model connection, referenced by name. Its own
       `fallbacks` chain applies, so failover here costs nothing extra.
    2. `media.audio.command`: a local command, for a machine that must not send audio
       anywhere. `{file}` is substituted with the path.
    3. No config at all: a connection you already have is used when its provider is known
       to transcribe (see `@transcribers`). Configuring OpenAI or Groq for chat is enough
       to make voice work, with nothing else to set up.

  When every route is absent or fails, `transcribe/1` returns `:unavailable` and the
  caller falls back to handing the file to the agent, which can still work it out with
  the tools it has. That path stays as a safety net; it is not the way in.
  """

  require Logger

  alias Pepe.Config
  alias Pepe.Config.Model

  # Providers that serve an OpenAI-compatible /audio/transcriptions, keyed by the host of
  # their base_url, with the transcription model to ask for. This is what makes the
  # zero-config route honest rather than a guess: we only reach for a connection the user
  # already has when we know that endpoint is actually there.
  @transcribers %{
    "api.openai.com" => "whisper-1",
    "api.groq.com" => "whisper-large-v3-turbo"
  }

  defp transcribers, do: Application.get_env(:pepe, :transcriber_hosts, @transcribers)

  # Below this, a file is empty or truncated rather than quiet, and no transcriber will
  # say anything useful about it. Failing here costs nothing; sending it costs a request.
  @min_bytes 1024

  @default_max_mb 20
  @default_timeout_s 60

  @doc """
  Transcribe the audio file at `path`.

  Returns `{:ok, text}`, or `:unavailable` when no route is configured or every route
  failed. An empty transcript (silence, or audio with no speech) is `{:ok, ""}`: the file
  was read, it just had nothing in it, which is a different thing from not being able to
  read it.
  """
  @spec transcribe(Path.t()) :: {:ok, String.t()} | :unavailable
  def transcribe(path) do
    with :ok <- readable(path),
         {:ok, text} <- run(path, settings()) do
      {:ok, String.trim(text)}
    else
      {:error, reason} ->
        Logger.info("[media] could not transcribe #{Path.basename(path)}: #{inspect(reason)}")
        :unavailable

      :unavailable ->
        :unavailable
    end
  end

  @doc "Whether a transcript should be echoed back to the chat (`media.audio.echo`)."
  @spec echo? :: boolean()
  def echo?, do: settings()["echo"] == true

  @doc "Audio settings from the config (`media.audio`), or `%{}`."
  @spec settings :: map()
  def settings, do: Config.media() |> Map.get("audio", %{})

  ###
  ### routes
  ###

  defp run(path, settings) do
    case route(settings) do
      {:model, model} -> via_model(path, model, settings)
      {:command, template} -> via_command(path, template, settings)
      :none -> :unavailable
    end
  end

  # An explicit model wins, then an explicit command, then a connection that happens to be
  # able to do this. The command is second, not last, because a machine that configured one
  # did so to keep audio local, and reaching past it to a provider would defeat the point.
  defp route(settings) do
    cond do
      model = configured_model(settings["model"]) -> {:model, model}
      is_binary(settings["command"]) and settings["command"] != "" -> {:command, settings["command"]}
      model = detected_model() -> {:model, model}
      true -> :none
    end
  end

  defp configured_model(nil), do: nil
  defp configured_model(name) when is_binary(name), do: Config.get_model(name)
  defp configured_model(_), do: nil

  # A connection the user already has, whose provider we know serves transcription. The
  # model id is ours, not theirs: they configured that connection to chat, so its `model`
  # names a chat model, which the transcription endpoint would reject.
  defp detected_model do
    known = transcribers()

    Enum.find_value(Config.models(), fn %Model{} = m ->
      case known[host(m.base_url)] do
        nil -> nil
        audio_model -> %{m | model: audio_model}
      end
    end)
  end

  defp host(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: h} when is_binary(h) -> h
      _ -> nil
    end
  end

  defp host(_), do: nil

  ###
  ### a provider
  ###

  defp via_model(path, %Model{} = model, settings) do
    url = String.trim_trailing(model.base_url, "/") <> "/audio/transcriptions"

    # The filename matters, and is not decoration: providers read the audio format off its
    # extension, and a part sent without one is rejected as an unknown format.
    form =
      [
        model: model.model,
        response_format: "text",
        file: {File.read!(path), filename: Path.basename(path)}
      ]
      |> put_language(settings["language"])

    req =
      Req.new(
        url: url,
        headers: headers(model),
        form_multipart: form,
        receive_timeout: timeout_ms(settings)
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: body}} -> {:ok, text_of(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, brief(body)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_language(form, lang) when is_binary(lang) and lang != "", do: [{:language, lang} | form]
  defp put_language(form, _), do: form

  defp headers(%Model{} = model) do
    base =
      case Model.resolved_api_key(model) do
        key when is_binary(key) and key != "" -> %{"authorization" => "Bearer " <> key}
        _ -> %{}
      end

    Map.merge(base, Model.resolved_headers(model))
  end

  # `response_format: "text"` asks for a bare string, but a provider that ignores it and
  # answers with the JSON shape is answering the same question, so read both.
  defp text_of(body) when is_binary(body), do: body
  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(other), do: inspect(other)

  ###
  ### a local command
  ###

  # `System.cmd/3` has no timeout of its own, so the run is wrapped in a task we can give
  # up on. A transcriber that wedges must not wedge the conversation behind it.
  defp via_command(path, template, settings) do
    command = String.replace(template, "{file}", path)
    task = Task.async(fn -> Pepe.Sandbox.cmd("sh", ["-c", command], stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms(settings)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {out, code}} -> {:error, {:exit, code, brief(out)}}
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  ###
  ### guards
  ###

  defp readable(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size < @min_bytes -> {:error, :too_small}
      {:ok, %{size: size}} -> within_limit(size)
      {:error, reason} -> {:error, reason}
    end
  end

  defp within_limit(size) do
    max = (settings()["max_mb"] || @default_max_mb) * 1_048_576
    if size > max, do: {:error, {:too_big, size}}, else: :ok
  end

  defp timeout_ms(settings), do: (settings["timeout"] || @default_timeout_s) * 1000

  defp brief(body), do: body |> to_string() |> String.slice(0, 200)
end
