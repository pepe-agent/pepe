defmodule Mix.Tasks.PepeMediaCliTest do
  @moduledoc """
  `mix pepe media` is the CLI surface for `media.tts` (spoken replies) and `media.audio`
  (voice-note transcription) - both previously hand-edit-config.json-only, unlike every other
  setting in the project. Pins: turning tts/audio on and off, that an unknown model connection
  is refused before anything is written, and that setting one audio field (`--echo`) doesn't
  silently wipe fields set by an earlier call (`put_media/2` replaces the whole kind's map, so
  the CLI itself must merge).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_media_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_model(%Config.Model{name: "tts-model", base_url: "http://x", model: "m"})
    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "media with nothing configured shows both kinds off" do
    out = pepe(["media"])
    assert out =~ "tts"
    assert out =~ "off"
    assert out =~ "audio"
  end

  test "tts --model turns spoken replies on, defaulting voice to alloy" do
    pepe(["media", "tts", "--model", "tts-model"])
    assert Config.media()["tts"] == %{"model" => "tts-model", "voice" => "alloy"}
  end

  test "tts --model --voice sets both" do
    pepe(["media", "tts", "--model", "tts-model", "--voice", "nova"])
    assert Config.media()["tts"] == %{"model" => "tts-model", "voice" => "nova"}
  end

  test "tts with an unknown model connection is refused, nothing written" do
    out = pepe_err(["media", "tts", "--model", "ghost"])
    assert out =~ "unknown model connection"
    assert Config.media()["tts"] in [nil, %{}]
  end

  test "tts off clears it" do
    pepe(["media", "tts", "--model", "tts-model"])
    pepe(["media", "tts", "off"])
    assert Config.media()["tts"] == %{}
  end

  test "audio --command sets a local transcriber" do
    pepe(["media", "audio", "--command", "whisper {file}", "--language", "pt"])
    assert Config.media()["audio"] == %{"command" => "whisper {file}", "language" => "pt"}
  end

  test "audio --model with an unknown connection is refused" do
    out = pepe_err(["media", "audio", "--model", "ghost"])
    assert out =~ "unknown model connection"
  end

  test "audio off clears it" do
    pepe(["media", "audio", "--command", "whisper {file}"])
    pepe(["media", "audio", "off"])
    assert Config.media()["audio"] == %{}
  end

  test "setting one audio field later merges, it does not wipe fields set earlier" do
    pepe(["media", "audio", "--model", "tts-model", "--language", "en"])
    pepe(["media", "audio", "--echo", "true"])

    assert Config.media()["audio"] == %{
             "model" => "tts-model",
             "language" => "en",
             "echo" => true
           }
  end

  test "audio --echo with a non-boolean value is refused" do
    out = pepe_err(["media", "audio", "--echo", "loud"])
    assert out =~ "true or false"
  end

  test "media help lists both subcommands" do
    out = pepe(["media", "help"])
    assert out =~ "tts"
    assert out =~ "audio"
  end
end
