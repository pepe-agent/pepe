defmodule Pepe.MediaTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Media

  # Stands in for a provider's /audio/transcriptions. Asserts on the way through that we
  # send what the OpenAI shape actually requires: multipart, with the *transcription*
  # model, not whatever model the connection was configured to chat with.
  defmodule TranscriberPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/audio/transcriptions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [type] = Plug.Conn.get_req_header(conn, "content-type")
      send(Agent.get(:media_test_pid, & &1), {:asked, body, type})

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, "  deploy the thing  ")
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "no")
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_media_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :media_test_pid)

    {:ok, server} = Bandit.start_link(plug: TranscriberPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # Something big enough to clear the "empty or truncated" floor.
    audio = Path.join(home, "voice.ogg")
    File.write!(audio, :binary.copy(<<0>>, 4096))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home, audio: audio, base_url: "http://127.0.0.1:#{port}"}
  end

  defp put_model(name, base_url, model \\ "chat-model") do
    Config.put_model(%Model{name: name, base_url: base_url, api_key: "sk-test", model: model})
  end

  describe "a configured model" do
    test "transcribes and trims", %{audio: audio, base_url: base} do
      put_model("scribe", base, "whisper-1")
      Config.put_media("audio", %{"model" => "scribe"})

      assert {:ok, "deploy the thing"} = Media.transcribe(audio)
      assert_receive {:asked, body, type}
      assert type =~ "multipart/form-data"
      assert body =~ "whisper-1"
    end

    test "passes the language hint when one is set", %{audio: audio, base_url: base} do
      put_model("scribe", base, "whisper-1")
      Config.put_media("audio", %{"model" => "scribe", "language" => "pt"})

      assert {:ok, _} = Media.transcribe(audio)
      assert_receive {:asked, body, _type}
      assert body =~ "language"
      assert body =~ "pt"
    end
  end

  describe "with nothing configured" do
    test "uses a connection that already serves transcription", %{audio: audio, base_url: base} do
      # Standing in for "the user has OpenAI configured, for chat". Nothing under `media`.
      Application.put_env(:pepe, :transcriber_hosts, %{"127.0.0.1" => "whisper-large-v3-turbo"})
      on_exit(fn -> Application.delete_env(:pepe, :transcriber_hosts) end)

      put_model("openai", base, "gpt-5")

      assert {:ok, "deploy the thing"} = Media.transcribe(audio)
      assert_receive {:asked, body, _type}

      # The connection names a *chat* model, which the transcription endpoint would
      # reject. We must ask for the provider's transcription model instead.
      assert body =~ "whisper-large-v3-turbo"
      refute body =~ "gpt-5"
    end

    test "is unavailable when no connection can transcribe", %{audio: audio} do
      put_model("local", "http://127.0.0.1:9/v1", "llama")

      assert :unavailable = Media.transcribe(audio)
      refute_receive {:asked, _, _}
    end
  end

  describe "a local command" do
    test "is used when set, and its output is the transcript", %{audio: audio} do
      Config.put_media("audio", %{"command" => "echo hello from disk"})
      assert {:ok, "hello from disk"} = Media.transcribe(audio)
    end

    test "receives the file path in place of {file}", %{audio: audio} do
      Config.put_media("audio", %{"command" => "basename {file}"})
      assert {:ok, "voice.ogg"} = Media.transcribe(audio)
    end

    test "a failing command is unavailable, not a crash", %{audio: audio} do
      Config.put_media("audio", %{"command" => "exit 3"})
      assert :unavailable = Media.transcribe(audio)
    end

    test "beats a detected connection, because it was set to keep audio local", %{audio: audio, base_url: base} do
      Application.put_env(:pepe, :transcriber_hosts, %{"127.0.0.1" => "whisper-1"})
      on_exit(fn -> Application.delete_env(:pepe, :transcriber_hosts) end)

      put_model("openai", base, "gpt-5")
      Config.put_media("audio", %{"command" => "echo stayed home"})

      assert {:ok, "stayed home"} = Media.transcribe(audio)
      refute_receive {:asked, _, _}
    end
  end

  describe "guards" do
    test "a truncated file is refused before a request is made", %{home: home, base_url: base} do
      put_model("scribe", base)
      Config.put_media("audio", %{"model" => "scribe"})

      tiny = Path.join(home, "tiny.ogg")
      File.write!(tiny, "x")

      assert :unavailable = Media.transcribe(tiny)
      refute_receive {:asked, _, _}
    end

    test "an oversized file is refused before a request is made", %{home: home, base_url: base} do
      put_model("scribe", base)
      Config.put_media("audio", %{"model" => "scribe", "max_mb" => 1})

      big = Path.join(home, "big.ogg")
      File.write!(big, :binary.copy(<<0>>, 2 * 1_048_576))

      assert :unavailable = Media.transcribe(big)
      refute_receive {:asked, _, _}
    end

    test "a missing file is unavailable", %{home: home} do
      Config.put_media("audio", %{"command" => "echo never runs"})
      assert :unavailable = Media.transcribe(Path.join(home, "gone.ogg"))
    end

    test "a wedged command gives up instead of hanging the conversation", %{audio: audio} do
      Config.put_media("audio", %{"command" => "sleep 30", "timeout" => 1})

      assert :unavailable = Media.transcribe(audio)
    end
  end

  test "echo? follows the config", %{} do
    refute Media.echo?()
    Config.put_media("audio", %{"echo" => true})
    assert Media.echo?()
  end
end
