defmodule Pepe.Gateways.TelegramMultibotTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Gateways.Telegram

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tgmb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "the legacy singular telegram config is the bot named \"default\"" do
    Config.put_telegram(%{"bot_token" => "abc", "agent" => "assistant"})

    assert [bot] = Config.telegram_bots()
    assert bot["name"] == "default"
    assert bot["agent"] == "assistant"
    assert Config.telegram_bot("default")["bot_token"] == "abc"
  end

  test "delivery to a topic session key extracts the bare chat id and the thread (send_file/cron)" do
    Config.put_telegram(%{"bot_token" => "t"})

    # A plain chat: no thread. A topic session key (`<chat>#t<thread>`): bare chat + the thread,
    # so send_file/cron reach the topic instead of sending an invalid `<chat>#t<thread>` chat id.
    assert {%{"name" => "default"}, "42", nil} = Telegram.resolve_delivery("42")
    assert {%{"name" => "default"}, "42", 99} = Telegram.resolve_delivery("42#t99")
  end

  test "a topic can be bound to an agent persistently, taking precedence over the bot's agent" do
    Config.put_telegram(%{"bot_token" => "t", "agent" => "assistant"})
    Config.put_agent(%Config.Agent{name: "engenheiro", tools: []})

    assert Config.telegram_topic_agent("default", -100, 7) == nil
    Config.bind_telegram_topic("default", -100, 7, "engenheiro")
    assert Config.telegram_topic_agent("default", -100, 7) == "engenheiro"

    # A different topic is unaffected; unbinding clears it.
    assert Config.telegram_topic_agent("default", -100, 8) == nil
    Config.bind_telegram_topic("default", -100, 7, nil)
    assert Config.telegram_topic_agent("default", -100, 7) == nil
  end

  test "a forum topic gets its own session and its sends are routed back to the topic" do
    Config.put_telegram(%{"bot_token" => "t"})
    Telegram.refresh_bot()

    # No topic (General, an ordinary group, or a DM): bare key, no thread field added.
    Telegram.put_thread(nil)
    assert Telegram.session_key(12_345) == "telegram:12345"
    assert Telegram.with_thread(%{chat_id: 12_345}) == %{chat_id: 12_345}

    # In a topic: the session key is suffixed (so the topic is its own conversation) and every
    # send carries message_thread_id (so the reply lands in that topic, not General).
    Telegram.put_thread(67)
    assert Telegram.session_key(12_345) == "telegram:12345#t67"
    assert Telegram.with_thread(%{chat_id: 12_345}) == %{chat_id: 12_345, message_thread_id: 67}
  after
    Telegram.put_thread(nil)
  end

  test "album parts sharing a media_group_id buffer into one entry; a different group is separate" do
    Config.put_telegram(%{"bot_token" => "t"})
    Telegram.refresh_bot()
    if :ets.whereis(:pepe_tg_albums) == :undefined, do: :ets.new(:pepe_tg_albums, [:set, :public, :named_table])
    :ets.delete_all_objects(:pepe_tg_albums)

    msg = fn caption ->
      %{"chat" => %{"id" => 9, "type" => "group"}, "from" => %{"id" => 1}, "message_id" => 1, "caption" => caption}
    end

    # Three photos of one album (only the first carries the caption) → one entry, three items.
    Telegram.buffer_album(msg.("look at these"), "f1", "photo", nil, "grp-A")
    Telegram.buffer_album(msg.(nil), "f2", "photo", nil, "grp-A")
    Telegram.buffer_album(msg.(nil), "f3", "photo", nil, "grp-A")
    # A different album is a separate entry.
    Telegram.buffer_album(msg.(nil), "g1", "photo", nil, "grp-B")

    [{_, a}] = :ets.lookup(:pepe_tg_albums, {9, nil, "grp-A"})
    [{_, b}] = :ets.lookup(:pepe_tg_albums, {9, nil, "grp-B"})

    assert [_, _, _] = a.items
    assert a.caption == "look at these"
    assert [_] = b.items
  after
    if :ets.whereis(:pepe_tg_albums) != :undefined, do: :ets.delete_all_objects(:pepe_tg_albums)
  end

  test "received reactions default to `own` - only on the bot's own messages, not any 👍" do
    if :ets.whereis(:pepe_tg_sent) == :undefined, do: :ets.new(:pepe_tg_sent, [:set, :public, :named_table])
    :ets.delete_all_objects(:pepe_tg_sent)
    # The bot sent message 100 in chat 9; message 200 is someone else's.
    :ets.insert(:pepe_tg_sent, {{9, 100}, System.system_time(:second)})

    react = fn msg_id, is_bot ->
      %{"chat" => %{"id" => 9, "type" => "group"}, "user" => %{"id" => 1, "is_bot" => is_bot}, "message_id" => msg_id}
    end

    # Default mode (own): a reaction on the bot's message counts; on another message it doesn't.
    Config.put_telegram(%{"bot_token" => "t"})
    Telegram.refresh_bot()
    assert Telegram.reaction_wanted?(react.(100, false))
    refute Telegram.reaction_wanted?(react.(200, false))
    refute Telegram.reaction_wanted?(react.(100, true))

    # off: never.
    Config.put_telegram(%{"bot_token" => "t", "reactions" => "off"})
    Telegram.refresh_bot()
    refute Telegram.reaction_wanted?(react.(100, false))

    # all: any non-bot reaction, even on a message the bot didn't send.
    Config.put_telegram(%{"bot_token" => "t", "reactions" => "all"})
    Telegram.refresh_bot()
    assert Telegram.reaction_wanted?(react.(200, false))
  after
    if :ets.whereis(:pepe_tg_sent) != :undefined, do: :ets.delete_all_objects(:pepe_tg_sent)
  end

  test "album_prompt lists every file and appends the caption" do
    out = Telegram.album_prompt(["media/a.jpg", "media/b.jpg"], "what are these?")
    assert out =~ "2 files"
    assert out =~ "`media/a.jpg`"
    assert out =~ "`media/b.jpg`"
    assert out =~ "what are these?"
  end

  test "flood-control retry_after is read from the error body, with a sane default" do
    assert Telegram.retry_after(%{"parameters" => %{"retry_after" => 12}}) == 12
    assert Telegram.retry_after(%{"ok" => false}) == 5
    assert Telegram.retry_after(%{"parameters" => %{"retry_after" => 0}}) == 5
  end

  test "with_reply ties a send to a message id, and is a no-op when there is none" do
    assert Telegram.with_reply(nil, %{chat_id: 1}) == %{chat_id: 1}

    assert Telegram.with_reply(42, %{chat_id: 1}) ==
             %{chat_id: 1, reply_parameters: %{message_id: 42, allow_sending_without_reply: true}}
  end

  test "a live config change (require_mention) is picked up by refresh_bot without a restart" do
    Config.put_telegram(%{"bot_token" => "t", "require_mention" => true})
    Telegram.refresh_bot()
    assert Telegram.bot()["require_mention"] == true

    # Operator flips it while the poller runs. The snapshot is stale until the next poll...
    Config.put_telegram(%{"bot_token" => "t", "require_mention" => false})
    assert Telegram.bot()["require_mention"] == true

    # ...until the next poll re-reads the config, which is what refresh_bot does.
    Telegram.refresh_bot()
    assert Telegram.bot()["require_mention"] == false
  end

  test "named bots live alongside the default, each bound to its own agent" do
    Config.put_telegram(%{"bot_token" => "default-token", "agent" => "assistant"})
    Config.put_telegram_bot("sales", %{"bot_token" => "sales-token", "agent" => "sales-bot"})
    Config.put_telegram_bot("ops", %{"bot_token" => "ops-token", "agent" => "ops-bot"})

    names = Config.telegram_bots() |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["default", "ops", "sales"]

    assert Config.telegram_bot("sales")["agent"] == "sales-bot"
    assert Config.telegram_bot("ops")["bot_token"] == "ops-token"
  end

  test "bots resolving to the same token are de-duplicated" do
    Config.put_telegram(%{"bot_token" => "same"})
    Config.put_telegram_bot("dup", %{"bot_token" => "same", "agent" => "x"})

    assert match?([_], Config.telegram_bots())
  end

  test "delete removes a named bot" do
    Config.put_telegram_bot("sales", %{"bot_token" => "t"})
    assert Config.telegram_bot("sales")

    Config.delete_telegram_bot("sales")
    refute Config.telegram_bot("sales")
  end

  test "bot_active? requires enabled and a resolvable token" do
    assert Telegram.bot_active?(%{"bot_token" => "t"})
    refute Telegram.bot_active?(%{"bot_token" => "t", "enabled" => false})
    refute Telegram.bot_active?(%{"agent" => "x"})
    refute Telegram.bot_active?(%{"bot_token" => ""})
  end

  test "bot_active? resolves ${ENV_VAR} tokens" do
    var = "PEPE_TEST_TG_TOKEN_#{System.unique_integer([:positive])}"
    refute Telegram.bot_active?(%{"bot_token" => "${#{var}}"})

    System.put_env(var, "real-token")
    assert Telegram.bot_active?(%{"bot_token" => "${#{var}}"})
    System.delete_env(var)
  end

  test "trainers allowlist decides who a bot learns from" do
    # null / missing -> learns from everyone
    assert Telegram.learns_from?(%{}, 111)
    assert Telegram.learns_from?(%{"trainers" => nil}, 111)
    # [] -> learns from no one (a client-facing bot)
    refute Telegram.learns_from?(%{"trainers" => []}, 111)
    # [ids] -> only those users
    assert Telegram.learns_from?(%{"trainers" => [111, 222]}, 111)
    refute Telegram.learns_from?(%{"trainers" => [111, 222]}, 999)
    # ["*"] -> everyone (explicit, the standard "all" token)
    assert Telegram.learns_from?(%{"trainers" => ["*"]}, 999)
  end

  test "delivering to an unknown/missing bot is a safe no-op" do
    # No bots configured -> nothing to deliver to, but never raises.
    assert Telegram.deliver("999", "hi") == :ok
    assert Telegram.deliver("nope:999", "hi") == :ok
  end
end
