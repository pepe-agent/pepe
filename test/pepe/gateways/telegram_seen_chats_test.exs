defmodule Pepe.Gateways.TelegramSeenChatsTest do
  @moduledoc """
  Every update a bot polls records the chat it came from (`Pepe.SeenChannels`), before any
  gate, so the bot's card on the Channels page can list its groups, topics and chats.
  """
  use ExUnit.Case, async: false

  alias Pepe.Gateways.Telegram
  alias Pepe.SeenChannels

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_tg_seen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # Outside a poller there is no bot snapshot in the process dictionary, so this is the
  # default bot, exactly as the poller of the legacy single bot sees itself.
  test "a group, a forum topic and a direct message are each recorded under the bot" do
    group = %{"id" => -100_1, "type" => "supergroup", "title" => "Ops team"}

    assert :ok = Telegram.note_chat(%{"message" => %{"chat" => group, "text" => "hi"}})

    assert :ok =
             Telegram.note_chat(%{
               "message" => %{"chat" => group, "text" => "hi", "is_topic_message" => true, "message_thread_id" => 7}
             })

    assert :ok =
             Telegram.note_chat(%{
               "edited_message" => %{
                 "chat" => %{"id" => 55, "type" => "private", "first_name" => "Ana", "last_name" => "Lima"},
                 "text" => "x"
               }
             })

    rows = SeenChannels.list("default") |> Map.new(&{&1.channel, &1})

    assert %{provider: "telegram", kind: "group", name: "Ops team"} = rows["-1001"]
    assert %{kind: "group", name: "Ops team"} = rows["-1001#t7"]
    assert %{kind: "dm", name: "Ana Lima"} = rows["55"]
  end

  test "an update that is not a message is ignored" do
    assert :ok = Telegram.note_chat(%{"callback_query" => %{"data" => "perm:1"}})
    assert [] = SeenChannels.list("default")
  end

  test "a channel's session key is the one the poller would use for it" do
    assert Telegram.channel_session_key("default", "-1001") == "telegram:-1001"
    assert Telegram.channel_session_key("default", "-1001#t7") == "telegram:-1001#t7"
    assert Telegram.channel_session_key("sales", "55") == "telegram:sales:55"
  end
end
