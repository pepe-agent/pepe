defmodule Pepe.Gateways.TelegramVoiceTest do
  @moduledoc """
  A voice note, end to end, against a mock Telegram API and a mock transcriber.

  The claim being tested is not "audio gets transcribed". It is that the transcript
  arrives *as the message*, through the same door a typed one uses, early enough for
  routing to see it. That is what makes a spoken slash command run, and what lets a bot
  in a group answer to hearing its own name.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @chat 4242
  @user 7

  # Plays Telegram (getUpdates / getFile / the file download / sendMessage) and the
  # transcription provider, so the gateway's real path runs against both.
  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json, :multipart], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      # See the note in the commands test: tolerate a torn-down Agent from a poll or a
      # background task that outlived the test.
      updates = safe_take(:tg_voice_updates, [])
      if updates == [], do: Process.sleep(20)
      json(conn, %{"ok" => true, "result" => updates})
    end

    get "/bot:token/getFile" do
      json(conn, %{"ok" => true, "result" => %{"file_path" => "voice/note.ogg"}})
    end

    # Without this the gateway does not know its own name, and `mentions_bot?` answers
    # `true` to everything rather than go silent. Mention gating only has teeth when the
    # bot can tell whether it was the one being spoken to.
    #
    # `:tg_voice_getme` can be flipped to :fail to make this look like a network blip, so
    # a test can check the gateway recovers instead of forgetting its own name for good.
    get "/bot:token/getMe" do
      case safe_get(:tg_voice_getme, :ok) do
        # 404 rather than 5xx: it fails the lookup just the same, and Req does not spend
        # three retries and seven seconds of backoff on it, which the suite would feel.
        :fail -> Plug.Conn.send_resp(conn, 404, "nope")
        _ -> json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
      end
    end

    # The audio itself, big enough to clear the "empty or truncated" floor.
    get "/file/bot:token/voice/note.ogg" do
      Plug.Conn.send_resp(conn, 200, :binary.copy(<<0>>, 4096))
    end

    # Stamped with the chat it was for. The gateway's reply tasks are unlinked and the API
    # base is global, so a straggler from another test file can land on this server after
    # its own has gone: without the chat id we would read its message as ours.
    post "/bot:token/sendMessage" do
      send(test_pid(), {:sent, conn.body_params["chat_id"], conn.body_params["text"] || ""})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})
    end

    post "/audio/transcriptions" do
      send(test_pid(), :transcribed)

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, safe_get(:tg_voice_said, ""))
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    defp test_pid, do: safe_get(:tg_voice_test_pid, self())

    defp safe_get(name, default), do: safe(fn -> Agent.get(name, & &1) end, default)
    defp safe_take(name, default), do: safe(fn -> Agent.get_and_update(name, &{&1, []}) end, default)

    defp safe(fun, default) do
      fun.()
    catch
      :exit, _ -> default
    end

    defp json(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tg_voice_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> [] end, name: :tg_voice_updates)
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :tg_voice_test_pid)
    {:ok, _} = Agent.start_link(fn -> "" end, name: :tg_voice_said)
    {:ok, _} = Agent.start_link(fn -> :ok end, name: :tg_voice_getme)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    Config.put_model(%Model{name: "scribe", base_url: base, api_key: "k", model: "whisper-1"})
    Config.put_media("audio", %{"model" => "scribe"})

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp start_bot!(extra \\ %{}) do
    bot = Map.merge(%{"name" => "default", "bot_token" => "t", "agent" => "assistant"}, extra)
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp says(text), do: Agent.update(:tg_voice_said, fn _ -> text end)

  defp send_voice(chat_type \\ "private") do
    update = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => @chat, "type" => chat_type},
        "from" => %{"id" => @user},
        "voice" => %{"file_id" => "f1"}
      }
    }

    Agent.update(:tg_voice_updates, &(&1 ++ [update]))
  end

  defp await_reply do
    assert_receive {:sent, @chat, text}, 5_000
    text
  end

  test "a spoken slash command runs, because routing sees the words" do
    start_bot!()
    says("/help")
    send_voice()

    assert_receive :transcribed, 5_000
    # /help, not an agent turn about a file sitting in a directory.
    assert await_reply() =~ "/new -"
  end

  test "silence is answered plainly, not sent to the agent" do
    start_bot!()
    says("   ")
    send_voice()

    assert await_reply() =~ "couldn't make out any speech"
  end

  test "the transcript is echoed back, and the command in it still runs" do
    Config.put_media("audio", %{"model" => "scribe", "echo" => true})
    start_bot!()
    says("/help")
    send_voice()

    assert await_reply() =~ "📝 /help"

    # Wait for the command's own reply too. Partly because echoing must not swallow it,
    # and partly because a reply left in flight when the test ends lands in the mailbox of
    # whichever test runs next: the gateway's reply tasks are unlinked, so nothing else
    # holds them back.
    assert await_reply() =~ "/new -"
  end

  describe "in a group that requires being addressed" do
    # A voice note carries no caption, so before the transcript existed there was nothing
    # for mention gating to read. Every voice note in a group was therefore either always
    # ignored or always answered, depending on which way you got the check wrong. Now the
    # gate reads the words, so it can tell the two apart.

    test "a spoken command gets through" do
      start_bot!(%{"require_mention" => true})
      says("/help")
      send_voice("group")

      assert_receive :transcribed, 5_000
      assert await_reply() =~ "/new -"
    end

    test "idle chatter the bot was not part of stays out" do
      start_bot!(%{"require_mention" => true})
      says("so anyway I told him the deploy could wait")
      send_voice("group")

      assert_receive :transcribed, 5_000
      refute_receive {:sent, @chat, _}, 500
    end

    test "a failed name lookup is not remembered as the answer" do
      # Not knowing our own name means answering everything, which is the right way to
      # fail. Remembering that we failed would make it permanent: one blip against getMe
      # and the bot talks over every group it is in until someone restarts it.
      Agent.update(:tg_voice_getme, fn _ -> :fail end)
      start_bot!(%{"require_mention" => true})

      says("first one, while the name lookup is down")
      send_voice("group")
      # It over-answers, as designed, because it cannot tell if it was addressed.
      assert_receive {:sent, @chat, _}, 5_000

      # The blip passes.
      Agent.update(:tg_voice_getme, fn _ -> :ok end)

      says("second one, and by now it knows who it is")
      send_voice("group")

      assert_receive :transcribed, 5_000
      refute_receive {:sent, @chat, _}, 500
    end
  end
end
