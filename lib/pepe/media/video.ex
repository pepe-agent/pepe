defmodule Pepe.Media.Video do
  @moduledoc """
  The words spoken in a video, for a channel that receives one.

  A video sent to an agent is mostly somebody talking, and reading it as a file to go and
  inspect turns every one into the same small research project a voice note used to be. So
  the soundtrack is pulled out (`ffmpeg`, mono 16 kHz, the first 5 minutes, so a long film
  cannot become an unbounded job) and read like any other audio (`Pepe.Media.transcribe/1`,
  routes and all).

  Both halves are optional and their absence is not an error: no `ffmpeg` on the machine,
  no transcription route configured, a video with no audio track, or an extraction that
  fails or takes too long all come back as `:unavailable`, and the caller hands the agent the
  file instead, which is what happened for every video before this existed. `ffmpeg` runs
  through `Pepe.Sandbox` with a timeout, because the file it parses was written by a
  stranger.
  """

  require Logger

  @max_seconds 300
  @timeout_ms 60_000

  @doc """
  Transcribe the soundtrack of the video at `path`: `{:ok, text}` (empty when nothing was
  said) or `:unavailable`.
  """
  @spec transcribe(Path.t()) :: {:ok, String.t()} | :unavailable
  def transcribe(path) do
    with true <- Pepe.Media.transcription_available?(),
         ffmpeg when is_binary(ffmpeg) <- ffmpeg(),
         {:ok, wav} <- extract(ffmpeg, path) do
      try do
        Pepe.Media.transcribe(wav)
      after
        File.rm(wav)
      end
    else
      _ -> :unavailable
    end
  end

  # `:ffmpeg_path` lets a machine point at a build outside its PATH (and lets a test stand
  # in for one); otherwise whatever `ffmpeg` the PATH resolves.
  defp ffmpeg, do: Application.get_env(:pepe, :ffmpeg_path) || System.find_executable("ffmpeg")

  defp extract(ffmpeg, path) do
    out = Path.join(System.tmp_dir!(), "pepe_video_audio_#{System.unique_integer([:positive])}.wav")

    args = [
      "-nostdin",
      "-v",
      "error",
      "-y",
      "-i",
      path,
      "-vn",
      "-ac",
      "1",
      "-ar",
      "16000",
      "-t",
      Integer.to_string(@max_seconds),
      "-c:a",
      "pcm_s16le",
      out
    ]

    task = Task.async(fn -> Pepe.Sandbox.cmd(ffmpeg, args, stderr_to_stdout: true) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} ->
        if File.regular?(out), do: {:ok, out}, else: :error

      other ->
        Logger.info("[media] could not extract the soundtrack of #{Path.basename(path)}: #{inspect(other)}")
        File.rm(out)
        :error
    end
  end
end
