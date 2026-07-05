defmodule Pepe.Media.Speech do
  @moduledoc """
  Text -> a spoken voice note: the mirror of `Pepe.Media` transcription. When `media.tts` names a
  model connection that serves an OpenAI-compatible `/audio/speech`, a reply to a voice message can
  come back as a voice message. Off unless configured.

  The lasting record stays the text reply; the audio is an extra, and it's length-capped so a long
  answer never becomes a five-minute clip. Output is Opus in an `.ogg`, exactly what Telegram's
  `sendVoice` wants.
  """

  alias Pepe.Config
  alias Pepe.Config.Model

  @max_chars 1500

  @doc "TTS settings from the config (`media.tts`), or `%{}`."
  @spec settings() :: map()
  def settings, do: Config.media() |> Map.get("tts", %{})

  @doc "Is text-to-speech configured (a model connection named under `media.tts`)?"
  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(settings()["model"])

  @doc "Speak `text` into an `.ogg` (Opus) file Telegram can send as a voice note. `{:ok, path}` or `{:error, reason}`."
  @spec speak(String.t()) :: {:ok, String.t()} | {:error, term()}
  def speak(text) when is_binary(text) do
    with %{"model" => name} when is_binary(name) <- settings(),
         %Model{} = model <- Config.get_model(name) do
      generate(model, String.slice(text, 0, @max_chars))
    else
      _ -> {:error, :not_configured}
    end
  end

  defp generate(model, text) do
    url = String.trim_trailing(model.base_url, "/") <> "/audio/speech"

    body = %{
      "model" => model.model,
      "input" => text,
      "voice" => settings()["voice"] || "alloy",
      "response_format" => "opus"
    }

    req = Req.new(url: url, headers: headers(model), json: body, receive_timeout: 60_000)

    case Req.post(req) do
      {:ok, %{status: 200, body: audio}} when is_binary(audio) and byte_size(audio) > 0 -> write(audio)
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(audio) do
    path = Path.join(System.tmp_dir!(), "pepe_tts_#{System.unique_integer([:positive])}.ogg")
    File.write!(path, audio)
    {:ok, path}
  end

  defp headers(%Model{} = model) do
    base =
      case Model.resolved_api_key(model) do
        key when is_binary(key) and key != "" -> %{"authorization" => "Bearer " <> key}
        _ -> %{}
      end

    Map.merge(base, Model.resolved_headers(model))
  end
end
