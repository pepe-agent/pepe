defmodule Pepe.Media.SpeechTest do
  @moduledoc """
  Text-to-speech: the reverse of transcription. Off unless `media.tts` names a model connection;
  when set, `speak/1` posts to that provider's `/audio/speech` and writes the Opus audio to an .ogg
  Telegram can send as a voice note. Length-capped so a long reply isn't a huge clip.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Media.Speech

  defmodule SpeechPlug do
    import Plug.Conn
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, raw, conn} = read_body(conn)
      send(pid, {:req, Jason.decode!(raw)})
      conn |> put_resp_content_type("audio/ogg") |> send_resp(200, "FAKE-OPUS-BYTES")
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp start_tts do
    {:ok, server} = Bandit.start_link(plug: {SpeechPlug, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "tts", base_url: "http://127.0.0.1:#{port}/v1", api_key: "x", model: "tts-1"})
    Config.put_media("tts", %{"model" => "tts", "voice" => "nova"})
  end

  test "unconfigured: not enabled, speak returns an error" do
    refute Speech.enabled?()
    assert Speech.speak("hi") == {:error, :not_configured}
  end

  test "configured: posts to /audio/speech and writes an .ogg voice file" do
    start_tts()
    assert Speech.enabled?()

    assert {:ok, path} = Speech.speak("olá, mundo")
    assert Path.extname(path) == ".ogg"
    assert File.read!(path) == "FAKE-OPUS-BYTES"
    File.rm(path)

    assert_receive {:req, body}, 2_000
    assert body["input"] == "olá, mundo"
    assert body["voice"] == "nova"
    assert body["response_format"] == "opus"
    assert body["model"] == "tts-1"
  end

  test "a very long reply is capped before it's spoken" do
    start_tts()
    assert {:ok, path} = Speech.speak(String.duplicate("a", 5_000))
    File.rm(path)

    assert_receive {:req, body}, 2_000
    assert String.length(body["input"]) <= 1_500
  end
end
