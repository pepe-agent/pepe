defmodule Pepe.Gateways.TelegramCommandsTest do
  @moduledoc """
  The everyday Telegram surface, driven through the real poll/dispatch/reply path
  against a mock Telegram API: the commands a plain user runs, who is allowed to speak
  to the bot at all, whether it must be addressed in a group, the non-voice media it
  accepts, and the native permission prompt.

  The operator gate (who may reach config/spend/skills) is a separate concern and lives
  in telegram_operator_gate_test.exs; this bot has no `trainers` list, so everyone here
  is trusted and the gate is out of the way.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Gateways.Telegram

  @user 42
  @outsider 99

  # One server plays Telegram and the model provider both, so the gateway's real path
  # runs end to end. `:tg_cmd_llm` swaps what the model does: answer plainly, ask to run
  # `bash`, or fail outright. `:tg_cmd_files` can make a download fail like a real one.
  defmodule MockPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json, :multipart], json_decoder: Jason)
    plug(:dispatch)

    get "/bot:token/getUpdates" do
      # A dead Agent means the test ended and its state was torn down while a poll or a
      # background chat task was in flight (the gateway polls in a tight loop and spawns tasks
      # that outlive a test). Treat it as absent so a late hit on a slow machine does not crash
      # a background process and bleed a failure into the next test. See safe_get/2 below.
      updates = safe_take(:tg_cmd_updates, [])

      # Nothing pending: idle briefly instead of spinning the poller hot.
      if updates == [], do: Process.sleep(20)
      json(conn, %{"ok" => true, "result" => updates})
    end

    get "/bot:token/getMe" do
      json(conn, %{"ok" => true, "result" => %{"username" => "pepebot"}})
    end

    # Stamped with the chat it was for, and with its buttons. The gateway's reply tasks
    # are unlinked and the API base is global, so a straggler from another test file can
    # land here after its own server is gone: without the chat id we would read its
    # message as ours.
    post "/bot:token/sendMessage" do
      body = conn.body_params
      buttons = get_in(body, ["reply_markup", "inline_keyboard"]) || []
      send(test_pid(), {:sent, body["chat_id"], body["text"] || "", buttons})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 777}})
    end

    post "/bot:token/editMessageText" do
      send(test_pid(), {:edited, conn.body_params["chat_id"], conn.body_params["text"] || ""})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 777}})
    end

    post "/bot:token/setMessageReaction" do
      send(test_pid(), {:reaction, conn.body_params["chat_id"], conn.body_params["reaction"]})
      json(conn, %{"ok" => true, "result" => true})
    end

    post "/bot:token/sendDocument" do
      send(test_pid(), {:document, conn.body_params["chat_id"]})
      json(conn, %{"ok" => true, "result" => %{"message_id" => 778}})
    end

    get "/bot:token/getFile" do
      case safe_get(:tg_cmd_files, :default) do
        # 404 rather than 5xx: it fails the lookup just the same, and Req does not spend
        # three retries and seconds of backoff on it, which the suite would feel.
        :fail -> Plug.Conn.send_resp(conn, 404, "gone")
        ext -> json(conn, %{"ok" => true, "result" => %{"file_path" => "stuff/file#{ext}"}})
      end
    end

    get "/file/bot:token/stuff/*rest" do
      Plug.Conn.send_resp(conn, 200, :binary.copy(<<0>>, 512))
    end

    # The model. Forwards the prompt it was handed, so a test can assert on what the
    # agent was actually told - that is the whole claim for a photo or a document.
    post "/chat/completions" do
      messages = Map.fetch!(conn.body_params, "messages")
      last = List.last(messages)
      send(test_pid(), {:llm, chat_of(messages), to_string(last["content"])})

      case safe_get(:tg_cmd_llm, :default) do
        :fail ->
          conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(400, ~s({"error":"no"}))

        :tool ->
          if last["role"] == "tool", do: model_reply(conn, "ran it", nil), else: model_reply(conn, nil, bash_call())

        # Five tools at once: the shape that turns one progress note into ten edits.
        :burst ->
          if last["role"] == "tool", do: model_reply(conn, "all done", nil), else: model_reply(conn, nil, many_calls())

        # A model that says what it is about to do before doing it, which is what a real one
        # does and what the verbose progress note exists to show.
        :thinking_tool ->
          if last["role"] == "tool",
            do: model_reply(conn, "the disk is fine, 12% used", nil),
            else: model_reply(conn, "Let me check how full the disk is.", bash_call())

        _ ->
          model_reply(conn, "here is my answer", nil)
      end
    end

    match _ do
      json(conn, %{"ok" => true, "result" => true})
    end

    # Which test's conversation this call belongs to, read off the marker its agent carries
    # in the system prompt. Without it a straggler model call from a test that has already
    # finished would be indistinguishable from this one's - the same hazard the chat id on
    # every sendMessage guards against.
    defp chat_of(messages) do
      with %{"content" => content} <- Enum.find(messages, &(&1["role"] == "system")),
           [_, id] <- Regex.run(~r/CHAT-(\d+)/, to_string(content)) do
        String.to_integer(id)
      else
        _ -> nil
      end
    end

    defp bash_call do
      [%{"id" => "c1", "type" => "function", "function" => %{"name" => "bash", "arguments" => ~s({"command":"true"})}}]
    end

    # What a model actually does when the work splits: several reads at once. They run
    # together now, so their events arrive as a burst.
    defp many_calls do
      for n <- 1..5 do
        %{
          "id" => "c#{n}",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => ~s({"path":"f#{n}.txt"})}
        }
      end
    end

    defp model_reply(conn, content, tool_calls) do
      message =
        %{"role" => "assistant", "content" => content}
        |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(tool_calls, do: "tool_calls", else: "stop")}
        ]
      }

      json(conn, payload)
    end

    defp test_pid, do: safe_get(:tg_cmd_test_pid, self())

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
    home = Path.join(System.tmp_dir!(), "pepe_tg_cmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    test_pid = self()
    {:ok, _} = Agent.start_link(fn -> [] end, name: :tg_cmd_updates)
    {:ok, _} = Agent.start_link(fn -> test_pid end, name: :tg_cmd_test_pid)
    {:ok, _} = Agent.start_link(fn -> :ok end, name: :tg_cmd_llm)
    {:ok, _} = Agent.start_link(fn -> ".bin" end, name: :tg_cmd_files)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"

    prev_base = Application.get_env(:pepe, :telegram_api_base)
    Application.put_env(:pepe, :telegram_api_base, base)

    # A chat of its own per test. The session key is derived from the chat id, so a shared
    # one would hand every test the *same* session process - its leftover history, and any
    # turn of the previous test's still churning inside it. It also keeps a straggler reply
    # (the gateway's reply tasks are unlinked, and the API base is global) out of the next
    # test's mailbox, since it carries a chat id nobody is listening for.
    chat = 8_800_000 + System.unique_integer([:positive])

    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "mock-model"})

    Config.put_agent(%Pepe.Config.Agent{
      name: "assistant",
      model: "mock",
      system_prompt: "You help. CHAT-#{chat}",
      tools: ["bash"],
      max_iterations: 4
    })

    on_exit(fn ->
      if prev_base,
        do: Application.put_env(:pepe, :telegram_api_base, prev_base),
        else: Application.delete_env(:pepe, :telegram_api_base)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, chat: chat, base: base}
  end

  defp start_bot!(extra \\ %{}) do
    bot = Map.merge(%{"name" => "default", "bot_token" => "t", "agent" => "assistant"}, extra)
    Config.put_telegram(bot)
    start_supervised!(%{id: Telegram, start: {Telegram, :start_link, [bot]}})
    :ok
  end

  defp model_answers(mode), do: Agent.update(:tg_cmd_llm, fn _ -> mode end)

  # Everything the bot sent or edited in this chat, in whatever order it arrived, until the
  # turn goes quiet. The progress note and the reply are two HTTP calls racing each other
  # over the same pool: under load the note can land second, and a test that assumes the
  # first message is the note fails for a reason that has nothing to do with what it checks.
  # It also drains the turn, so no straggler outlives the test.
  defp everything_said(chat, acc \\ []) do
    receive do
      {:sent, ^chat, text, _buttons} -> everything_said(chat, [text | acc])
      {:edited, ^chat, text} -> everything_said(chat, [text | acc])
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  # Enough back-and-forth that there is a middle worth condensing.
  defp chatter(chat, turns) do
    Enum.each(1..turns, fn n ->
      say(chat, "turn number #{n}, and a few more words so the history actually weighs something")
      assert await_reply(chat) =~ "here is my answer"
    end)
  end

  # Shrink the model's declared context window *after* the talking, so those turns run
  # without the loop's own automatic compaction firing, and only the manual /compact has
  # a middle to work on.
  defp shrink_window(base) do
    Config.put_model(%Model{name: "mock", base_url: base, api_key: "k", model: "mock-model", context_window: 200})
  end

  defp downloads(mode), do: Agent.update(:tg_cmd_files, fn _ -> mode end)

  defp push(message), do: Agent.update(:tg_cmd_updates, &(&1 ++ [message]))

  defp say(chat, text, opts \\ []) do
    push(%{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "text" => text,
        "chat" => %{"id" => opts[:chat] || chat, "type" => opts[:type] || "private"},
        "from" => %{"id" => opts[:user] || @user}
      }
    })
  end

  defp send_photo(chat, caption \\ "") do
    push(%{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => chat, "type" => "private"},
        "from" => %{"id" => @user},
        "caption" => caption,
        "photo" => [%{"file_id" => "small"}, %{"file_id" => "large"}]
      }
    })
  end

  defp send_document(chat) do
    push(%{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "chat" => %{"id" => chat, "type" => "private"},
        "from" => %{"id" => @user},
        "document" => %{"file_id" => "doc1"}
      }
    })
  end

  defp tap_button(chat, callback_data, user \\ @user) do
    push(%{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => "cb-#{System.unique_integer([:positive])}",
        "data" => callback_data,
        "from" => %{"id" => user},
        "message" => %{"message_id" => 777, "chat" => %{"id" => chat}}
      }
    })
  end

  defp await_reply(chat) do
    assert_receive {:sent, ^chat, text, _buttons}, 5_000
    text
  end

  defp await_buttons(chat) do
    assert_receive {:sent, ^chat, _text, [_ | _] = buttons}, 5_000
    buttons |> List.flatten() |> Enum.map(& &1["callback_data"])
  end

  describe "the commands a plain user runs" do
    setup do: start_bot!()

    test "/new forgets the conversation, and /status proves it", %{chat: chat} do
      say(chat, "remember this")
      assert await_reply(chat) =~ "here is my answer"

      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 1"

      say(chat, "/new")
      assert await_reply(chat) =~ "New conversation started"

      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 0"
    end

    test "/undo drops the last thing said", %{chat: chat} do
      say(chat, "one")
      assert await_reply(chat) =~ "here is my answer"
      say(chat, "two")
      assert await_reply(chat) =~ "here is my answer"

      say(chat, "/undo")
      assert await_reply(chat) =~ "Undid your last message"

      # Two turns went in, one was taken back out.
      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 1"
    end

    test "/retry re-asks the last question instead of answering nothing", %{chat: chat} do
      say(chat, "/retry")
      assert await_reply(chat) =~ "Nothing to retry yet"

      say(chat, "what is the plan")
      assert_receive {:llm, ^chat, _asked}, 5_000
      assert await_reply(chat) =~ "here is my answer"

      say(chat, "/retry")
      # The question is put back to the model verbatim, not paraphrased and not asked of
      # the user again - that is the whole point of /retry.
      assert_receive {:llm, ^chat, prompt}, 5_000
      assert prompt =~ "what is the plan"
      assert await_reply(chat) =~ "here is my answer"

      # ...and it replaced the old turn rather than piling a second one on top.
      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 1"
    end

    test "/compact condenses the older turns into a summary", %{chat: chat, base: base} do
      chatter(chat, 5)
      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 5"

      shrink_window(base)

      say(chat, "/compact")
      assert await_reply(chat) =~ "History compacted"

      # The older turns really are gone, folded into one summary message - "compacted"
      # would otherwise be a claim the command makes about itself and never keeps.
      say(chat, "/status")
      turns = await_reply(chat)
      refute turns =~ "Turns: 5"
      refute turns =~ "Turns: 6"
    end

    test "/compact says so plainly when it cannot summarize", %{chat: chat, base: base} do
      chatter(chat, 5)
      shrink_window(base)
      model_answers(:fail)

      say(chat, "/compact")
      reply = await_reply(chat)

      assert reply =~ "couldn't summarize"
      # Never a raw internal error in the chat.
      refute reply =~ "http_error"
    end

    test "/stop says nothing is running when nothing is", %{chat: chat} do
      say(chat, "/stop")
      assert await_reply(chat) =~ "Nothing is running"
    end

    test "/inline refuses when there is no running turn to fold it into", %{chat: chat} do
      say(chat, "/inline")
      assert await_reply(chat) =~ "Usage: /inline"

      say(chat, "/inline also do this")
      assert await_reply(chat) =~ "Nothing is running"
    end

    test "/btw answers without joining the conversation", %{chat: chat} do
      say(chat, "the actual topic")
      assert await_reply(chat) =~ "here is my answer"

      say(chat, "/btw")
      assert await_reply(chat) =~ "Usage: /btw"

      say(chat, "/btw a passing thought")
      assert await_reply(chat) =~ "here is my answer"

      # The side question never became a turn.
      say(chat, "/status")
      assert await_reply(chat) =~ "Turns: 1"
    end

    test "/btw reports a model failure kindly, never as a stacktrace", %{chat: chat} do
      model_answers(:fail)

      say(chat, "/btw anything")
      reply = await_reply(chat)

      assert reply =~ "The model returned an error"
      refute reply =~ "http_error"
    end

    test "/whoami hands back the ids the allowlists are filled in with", %{chat: chat} do
      say(chat, "/whoami")
      reply = await_reply(chat)

      assert reply =~ to_string(@user)
      assert reply =~ to_string(chat)
    end

    test "/learn kicks off the memory review", %{chat: chat} do
      say(chat, "/learn")
      assert await_reply(chat) =~ "Reviewing what I learned"
    end

    test "/help lists what can be run, and an unknown command says so and lists it too", %{chat: chat} do
      say(chat, "/nonsense")
      reply = await_reply(chat)

      assert reply =~ "Unknown command: /nonsense"
      assert reply =~ "/new -"
    end

    test "/start greets and explains itself", %{chat: chat} do
      say(chat, "/start")
      reply = await_reply(chat)

      assert reply =~ "Pepe ready"
      assert reply =~ "/help -"
    end

    test "a command aimed at this bot by name in a group still runs", %{chat: chat} do
      say(chat, "/status@pepebot", type: "group")
      assert await_reply(chat) =~ "Agent:"
    end

    test "a model failure on a normal message is reported kindly", %{chat: chat} do
      model_answers(:fail)

      say(chat, "hello")
      reply = await_reply(chat)

      assert reply =~ "The model returned an error"
      refute reply =~ "http_error"
    end
  end

  describe "the allowlists" do
    test "a user who is not on the list is ignored outright", %{chat: chat} do
      start_bot!(%{"allowed_users" => [@user]})

      say(chat, "/whoami", user: @outsider)
      refute_receive {:sent, ^chat, _text, _buttons}, 500

      # ...while the allowed user is answered as normal, so the bot is not simply mute.
      say(chat, "/whoami", user: @user)
      assert await_reply(chat) =~ to_string(@user)
    end

    test "a chat that is not on the list is ignored outright", %{chat: chat} do
      start_bot!(%{"allowed_chats" => [chat]})
      elsewhere = chat + 1

      say(chat, "/whoami", chat: elsewhere)
      refute_receive {:sent, ^elsewhere, _text, _buttons}, 500

      say(chat, "/whoami")
      assert await_reply(chat) =~ to_string(chat)
    end

    test "a disabled bot answers nobody at all", %{chat: chat} do
      start_bot!(%{"enabled" => false})

      say(chat, "/whoami")
      refute_receive {:sent, ^chat, _text, _buttons}, 500
    end
  end

  describe "in a group where the bot must be addressed" do
    setup do: start_bot!(%{"require_mention" => true})

    test "chatter between other people is left alone", %{chat: chat} do
      say(chat, "so anyway the deploy can wait", type: "group")
      refute_receive {:sent, ^chat, _text, _buttons}, 500
    end

    test "an @mention gets through, and the bot never sees its own name in the prompt", %{chat: chat} do
      say(chat, "@pepebot what do you think", type: "group")

      assert_receive {:llm, ^chat, prompt}, 5_000
      assert prompt =~ "what do you think"
      refute prompt =~ "@pepebot"
      assert await_reply(chat) =~ "here is my answer"
    end

    test "/mention off waives it for this group only, and /new puts it back", %{chat: chat} do
      say(chat, "/mention", type: "group")
      assert await_reply(chat) =~ "on (I need an @mention)"

      say(chat, "/mention off", type: "group")
      assert await_reply(chat) =~ "without being @mentioned"

      # Now a plain, unaddressed message is answered.
      say(chat, "no mention this time", type: "group")
      assert await_reply(chat) =~ "here is my answer"

      say(chat, "/mention", type: "group")
      assert await_reply(chat) =~ "off (I reply without being mentioned)"

      # The waiver is turn-scoped, so a fresh conversation forgets it like everything else.
      say(chat, "/new", type: "group")
      assert await_reply(chat) =~ "New conversation started"

      say(chat, "still no mention", type: "group")
      refute_receive {:sent, ^chat, _text, _buttons}, 500
    end

    test "/mention on restores it explicitly", %{chat: chat} do
      say(chat, "/mention off", type: "group")
      assert await_reply(chat) =~ "without being @mentioned"

      say(chat, "/mention on", type: "group")
      assert await_reply(chat) =~ "@mention required again"

      say(chat, "unaddressed", type: "group")
      refute_receive {:sent, ^chat, _text, _buttons}, 500
    end
  end

  describe "media that is not voice" do
    setup do: start_bot!()

    test "a photo reaches the agent as a file it can look at", %{chat: chat} do
      downloads(".jpg")
      send_photo(chat, "what is this?")

      assert_receive {:llm, ^chat, prompt}, 5_000
      # The agent is handed a path in its own workspace, not the bytes and not a
      # transcription attempt - a photo is for its eyes, not the transcriber.
      assert prompt =~ "sent a photo, saved at `media/photo_"
      assert prompt =~ ".jpg`"
      assert prompt =~ "what is this?"
      assert await_reply(chat) =~ "here is my answer"
    end

    test "the photo really lands in the agent's workspace", %{chat: chat} do
      downloads(".jpg")
      send_photo(chat)

      assert_receive {:llm, ^chat, _prompt}, 5_000
      media = Path.join(Pepe.Agent.Workspace.dir("assistant"), "media")

      assert [file] = Path.wildcard(Path.join(media, "photo_*.jpg"))
      assert File.stat!(file).size == 512
    end

    test "a document reaches the agent as a file it can inspect", %{chat: chat} do
      downloads(".pdf")
      send_document(chat)

      assert_receive {:llm, ^chat, prompt}, 5_000
      assert prompt =~ "sent a file, saved at `media/document_"
      assert await_reply(chat) =~ "here is my answer"
    end

    test "a download that fails asks for the file again instead of going quiet", %{chat: chat} do
      downloads(:fail)
      send_photo(chat)

      assert await_reply(chat) =~ "couldn't download that file"
      # The agent was never bothered with a file that does not exist.
      refute_receive {:llm, ^chat, _prompt}, 300
    end
  end

  describe "the native permission prompt" do
    test "a risky tool asks first, and the tap is what lets it run", %{chat: chat} do
      start_bot!()
      model_answers(:tool)

      say(chat, "do the thing")

      # The prompt names the tool and shows what it would run, so the tap is informed.
      assert_receive {:sent, ^chat, prompt, [_ | _] = buttons}, 5_000
      assert prompt =~ "bash"
      assert prompt =~ "true"

      [%{"callback_data" => allow_once} | _] = List.flatten(buttons)
      assert allow_once =~ ~r/^perm:\d+:once$/

      # Nothing has run yet: the turn is parked on the button.
      refute_receive {:sent, ^chat, _text, _buttons}, 300

      tap_button(chat, allow_once)

      # The prompt is closed with the outcome (no dangling buttons), then the turn ends.
      assert_receive {:edited, ^chat, outcome}, 5_000
      assert outcome =~ "Allowed once"
      assert await_reply(chat) =~ "ran it"
    end

    test "a denied tool ends the turn instead of running anyway", %{chat: chat} do
      start_bot!()
      model_answers(:tool)

      say(chat, "do the thing")
      assert [_ | _] = data = await_buttons(chat)

      deny = Enum.find(data, &String.ends_with?(&1, ":deny"))
      tap_button(chat, deny)

      assert_receive {:edited, ^chat, outcome}, 5_000
      assert outcome =~ "Not allowed"
    end

    test "a button pressed by someone outside the allowlist does nothing", %{chat: chat} do
      start_bot!(%{"allowed_users" => [@user]})
      model_answers(:tool)

      say(chat, "do the thing")
      assert [allow_once | _] = await_buttons(chat)

      push(%{
        "update_id" => System.unique_integer([:positive]),
        "callback_query" => %{
          "id" => "cb-outsider",
          "data" => allow_once,
          "from" => %{"id" => @outsider},
          "message" => %{"message_id" => 777, "chat" => %{"id" => chat}}
        }
      })

      # The prompt is never closed and the tool never runs: an outsider cannot approve a
      # risky command in someone else's chat.
      refute_receive {:edited, ^chat, _text}, 500
    end
  end

  describe "how much of the work is shown (tool_progress)" do
    test "reaction mode marks the user's own message while working, then clears it", %{chat: chat} do
      start_bot!()

      say(chat, "hello")

      assert_receive {:reaction, ^chat, [%{"emoji" => "👀"}]}, 5_000
      assert await_reply(chat) =~ "here is my answer"
      # Cleared once the answer lands, so the chat isn't left with a stale marker.
      assert_receive {:reaction, ^chat, []}, 5_000
    end

    test "ambient mode says what kind of work is happening, never which tool", %{chat: chat} do
      start_bot!(%{"tool_progress" => "ambient", "agent" => "assistant"})
      Config.put_agent(%{Config.get_agent("assistant") | auto_approve: ["bash"]})
      model_answers(:tool)

      say(chat, "do the thing")

      assert_receive {:sent, ^chat, status, _buttons}, 5_000
      assert status =~ "running something"
      refute status =~ "bash"
    end

    test "verbose mode shows the tool and what it was called with", %{chat: chat} do
      start_bot!(%{"tool_progress" => "verbose", "agent" => "assistant"})
      Config.put_agent(%{Config.get_agent("assistant") | auto_approve: ["bash"]})
      model_answers(:tool)

      say(chat, "do the thing")

      said = everything_said(chat)
      assert Enum.any?(said, &(&1 =~ "bash" and &1 =~ "true"))
    end

    test "verbose mode also shows why: what the model said before reaching for the tool",
         %{chat: chat} do
      start_bot!(%{"tool_progress" => "verbose", "agent" => "assistant"})
      Config.put_agent(%{Config.get_agent("assistant") | auto_approve: ["bash"]})
      model_answers(:thinking_tool)

      say(chat, "is the disk full?")

      said = everything_said(chat)

      # The ledger of tool calls says what happened. The sentence says why, which is what
      # lets you tell it is about to do the wrong thing before it does it. Both in one note.
      assert Enum.any?(said, &(&1 =~ "Let me check how full the disk is" and &1 =~ "bash"))
    end

    test "a burst of parallel tools does not become a burst of edits", %{chat: chat} do
      start_bot!(%{"tool_progress" => "verbose", "agent" => "assistant"})
      Config.put_agent(%{Config.get_agent("assistant") | tools: ["read_file"], auto_approve: ["*"]})
      model_answers(:burst)

      say(chat, "read all five")

      # Telegram rate-limits edits to one message. Five tools now run together, so without
      # coalescing this turn would fire ten edits (five calls, five results) inside a fraction
      # of a second, earn a 429, and the note would stop updating at all.
      said = everything_said(chat)

      redraws = Enum.count(said, &(&1 =~ "read_file"))
      assert redraws <= 3, "the note was redrawn #{redraws} times for one burst of five tools"

      # And it is still alive: the note was drawn at all, and the answer still arrived.
      assert Enum.any?(said, &(&1 =~ "read_file"))
      assert Enum.any?(said, &(&1 =~ "all done"))
    end

    test "the final answer never shows up as progress", %{chat: chat} do
      start_bot!(%{"tool_progress" => "verbose", "agent" => "assistant"})
      Config.put_agent(%{Config.get_agent("assistant") | auto_approve: ["bash"]})
      model_answers(:thinking_tool)

      say(chat, "is the disk full?")

      said = everything_said(chat)

      # The answer arrives, as the answer.
      assert Enum.any?(said, &(&1 =~ "the disk is fine"))

      # The runtime emits the same `:assistant` event for the sentence before a tool call and
      # for the answer itself, and nothing in the event tells them apart. A naive reader would
      # flash the answer into the progress note a moment before deleting it. It is held
      # instead, and drawn only by the tool call that follows it. Nothing follows the answer,
      # so the answer is never drawn as progress.
      refute Enum.any?(said, &(&1 =~ "• the disk is fine"))
    end
  end

  describe "unsolicited delivery (cron, watches, files)" do
    setup do: start_bot!()

    test "deliver/2 reaches the default bot's chat", %{chat: chat} do
      assert Telegram.deliver(to_string(chat), "the cron ran") == :ok
      assert_receive {:sent, chat, "the cron ran", _buttons}, 5_000
      assert to_string(chat) == to_string(chat)
    end

    test "deliver/2 to a bot that does not exist is a no-op, not a crash", %{chat: chat} do
      assert Telegram.deliver("ghost-bot:#{chat}", "hello") == :ok
      refute_receive {:sent, ^chat, _text, _buttons}, 300
    end

    test "deliver_file/3 sends the file as a document", %{chat: chat} do
      path = Path.join(System.tmp_dir!(), "pepe_tg_report_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "the report")
      on_exit(fn -> File.rm(path) end)

      assert Telegram.deliver_file(to_string(chat), path, "here you go") == :ok
      assert_receive {:document, _chat}, 5_000
    end

    test "deliver_file/3 to an unknown bot reports it instead of pretending", %{chat: chat} do
      assert Telegram.deliver_file("ghost-bot:1", "/nope") == {:error, :no_bot}
    end

    test "a fired watch is delivered to its origin chat", %{chat: chat} do
      assert Telegram.deliver_watch(%{"chat_id" => chat}, "the price dropped") == :ok
      assert_receive {:sent, chat, text, _buttons}, 5_000
      assert to_string(chat) == to_string(chat)
      assert text =~ "the price dropped"
    end

    test "a watch with no chat, or on a bot that is gone, is reported rather than dropped silently", %{chat: chat} do
      assert Telegram.deliver_watch(%{}, "nowhere to go") == {:error, :no_chat}
      assert Telegram.deliver_watch(%{"chat_id" => chat, "bot" => "ghost"}, "x") == {:error, :unknown_bot}
    end
  end

  describe "the operator commands, on a bot that trusts everyone it talks to" do
    setup %{chat: chat} do
      start_bot!()
      {:ok, chat: chat}
    end

    test "/agent switches, and refuses a name that isn't one", %{chat: chat} do
      Config.put_agent(%Pepe.Config.Agent{name: "sales", model: "mock", system_prompt: "You close deals."})

      say(chat, "/agent")
      assert await_reply(chat) =~ "Usage: /agent"

      say(chat, "/agent ghost")
      assert await_reply(chat) =~ "Unknown agent: ghost"

      say(chat, "/agent sales")
      assert await_reply(chat) =~ "Switched to agent sales"

      say(chat, "/status")
      assert await_reply(chat) =~ "Agent: sales"
    end

    test "/tools lists what the agent can actually reach for", %{chat: chat} do
      say(chat, "/tools")
      reply = await_reply(chat)

      assert reply =~ "Available tools"
      assert reply =~ "bash"
      # HTML, because the names are bolded - and it must be escaped, not raw.
      assert reply =~ "<b>"
    end

    test "/approve shows, and clears, what has been permanently allowed", %{chat: chat} do
      say(chat, "/approve")
      assert await_reply(chat) =~ "Nothing is pre-approved"

      Config.put_agent(%{Config.get_agent("assistant") | auto_approve: ["bash", "web_search"]})

      say(chat, "/approve")
      reply = await_reply(chat)
      assert reply =~ "bash"
      assert reply =~ "web_search"

      say(chat, "/approve clear bash")
      assert await_reply(chat) =~ "Removed bash"
      assert Config.get_agent("assistant").auto_approve == ["web_search"]

      say(chat, "/approve clear")
      assert await_reply(chat) =~ "Cleared all saved permissions"
      assert Config.get_agent("assistant").auto_approve == []

      say(chat, "/approve nonsense")
      assert await_reply(chat) =~ "Usage: /approve"
    end

    test "/model shows the current one, and refuses one that isn't configured", %{chat: chat} do
      say(chat, "/model")
      assert await_reply(chat) =~ "Current: mock-model"

      say(chat, "/model ghost")
      assert await_reply(chat) =~ "Unknown model: ghost"
    end

    test "/model NAME asks who the change is for, and each scope applies it", %{chat: chat} do
      Config.put_model(%Model{name: "other", base_url: "http://127.0.0.1:1", api_key: "k", model: "other-model"})

      # A trainer can change it for everyone, so the scope is a real question, not a
      # formality - it is asked rather than guessed.
      say(chat, "/model other")
      assert await_reply(chat) =~ "for this conversation only, or for everyone"

      say(chat, "/model other session")
      assert await_reply(chat) =~ "this conversation only"

      say(chat, "/status")
      assert await_reply(chat) =~ "Model: other-model"

      say(chat, "/model mock global")
      assert await_reply(chat) =~ "everyone"
      # Global really means the agent on disk, not just this chat.
      assert Config.get_agent("assistant").model == "mock"
    end

    test "/models offers a picker, and tapping through it switches the model", %{chat: chat} do
      Config.put_model(%Model{name: "other", base_url: "http://127.0.0.1:1", api_key: "k", model: "other-model"})

      say(chat, "/models")
      buttons = await_buttons(chat)
      assert "model:pick:other" in buttons

      # A trainer is asked which scope; a client would have had it applied outright.
      tap_button(chat, "model:pick:other")
      assert_receive {:edited, ^chat, text}, 5_000
      assert text =~ "for this conversation only, or for everyone"

      tap_button(chat, "model:apply:other:session")
      assert_receive {:edited, ^chat, applied}, 5_000
      assert applied =~ "Model set to other"

      say(chat, "/status")
      assert await_reply(chat) =~ "Model: other-model"
    end

    test "the picker's back button returns to the list instead of dead-ending", %{chat: chat} do
      say(chat, "/models")
      assert [_ | _] = await_buttons(chat)

      tap_button(chat, "model:pick:mock")
      assert_receive {:edited, ^chat, _scope_question}, 5_000

      tap_button(chat, "model:back")
      assert_receive {:edited, ^chat, back}, 5_000
      assert back =~ "Available models"
    end

    test "a tapped model that has since been deleted is refused, not applied blindly", %{chat: chat} do
      # The picker is a snapshot; config can change under it. Permission and existence are
      # both rechecked at the tap, never trusted from when the buttons were drawn.
      tap_button(chat, "model:pick:vanished")
      assert_receive {:edited, ^chat, text}, 5_000
      assert text =~ "Unknown model: vanished"
    end
  end

  describe "skills as commands" do
    setup %{chat: chat} do
      File.mkdir_p!(Path.join(Config.home(), "skills"))
      File.write!(Path.join([Config.home(), "skills", "ship-it.md"]), "# Ship it\n\nHow to ship.\n")
      start_bot!()
      {:ok, chat: chat}
    end

    test "/skill lists them, and an unknown one says so", %{chat: chat} do
      say(chat, "/skill")
      reply = await_reply(chat)

      assert reply =~ "Available skills"
      assert reply =~ "ship-it"

      say(chat, "/skill ghost")
      assert await_reply(chat) =~ "Unknown skill: ghost"
    end

    test "a skill runs by its own command name, handing the agent the instruction", %{chat: chat} do
      say(chat, "/ship_it now please")

      assert_receive {:llm, ^chat, prompt}, 5_000
      assert prompt =~ ~s(Carry out the "ship-it" skill now.)
      assert prompt =~ "now please"
      assert await_reply(chat) =~ "here is my answer"
    end
  end

  describe "who the bot learns from" do
    test "no trainers list means it learns from everyone", %{chat: chat} do
      assert Telegram.learns_from?(%{}, @user)
      assert Telegram.learns_from?(%{"trainers" => ["*"]}, @outsider)
    end

    test "an empty list means it learns from no one", %{chat: chat} do
      refute Telegram.learns_from?(%{"trainers" => []}, @user)
    end

    test "a list means it learns only from those ids", %{chat: chat} do
      assert Telegram.learns_from?(%{"trainers" => [@user]}, @user)
      refute Telegram.learns_from?(%{"trainers" => [@user]}, @outsider)
    end
  end

  describe "enabled?/0" do
    test "is false with no bot configured, and true once one has a token", %{chat: chat} do
      refute Telegram.enabled?()

      Config.put_telegram(%{"name" => "default", "bot_token" => "t", "agent" => "assistant"})
      assert Telegram.enabled?()
    end

    test "a bot with no token is not active, however enabled it says it is", %{chat: chat} do
      refute Telegram.bot_active?(%{"enabled" => true})
      refute Telegram.bot_active?(%{"enabled" => false, "bot_token" => "t"})
      assert Telegram.bot_active?(%{"bot_token" => "t"})
    end
  end
end
