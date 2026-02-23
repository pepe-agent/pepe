defmodule Pepe.Tools.ManageChannelTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.ManageChannel

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_chan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # An agent the bots can be bound to.
    Config.put_agent(%Agent{name: "sales-bot", system_prompt: "x", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(_ \\ nil), do: %{agent: %Agent{name: "boss"}}

  test "adds a bot with the token stored as an ${ENV} reference (secret stays out of chat)" do
    args = %{
      "action" => "add",
      "name" => "sales",
      "token_env" => "SALES_TOKEN",
      "agent" => "sales-bot"
    }

    assert {:ok, out} = ManageChannel.run(args, ctx())
    assert out =~ "sales"

    bot = Config.telegram_bot("sales")
    assert bot["bot_token"] == "${SALES_TOKEN}"
    assert bot["agent"] == "sales-bot"
  end

  test "rejects a raw token - must be an env var NAME" do
    args = %{
      "action" => "add",
      "name" => "sales",
      "token_env" => "123456:AA-raw-telegram-token",
      "agent" => "sales-bot"
    }

    assert {:error, msg} = ManageChannel.run(args, ctx())
    assert msg =~ "environment-variable NAME"
    refute Config.telegram_bot("sales")
  end

  test "refuses to touch the protected default bot" do
    args = %{"action" => "add", "name" => "default", "token_env" => "T", "agent" => "sales-bot"}
    assert {:error, msg} = ManageChannel.run(args, ctx())
    assert msg =~ "protected"
  end

  test "rejects binding to an unknown agent" do
    args = %{"action" => "add", "name" => "sales", "token_env" => "T", "agent" => "ghost"}
    assert {:error, msg} = ManageChannel.run(args, ctx())
    assert msg =~ "unknown agent"
  end

  test "set_agent, disable and remove operate on an existing bot" do
    ManageChannel.run(
      %{"action" => "add", "name" => "sales", "token_env" => "T", "agent" => "sales-bot"},
      ctx()
    )

    Config.put_agent(%Agent{name: "other", system_prompt: "x", tools: []})

    assert {:ok, _} =
             ManageChannel.run(
               %{"action" => "set_agent", "name" => "sales", "agent" => "other"},
               ctx()
             )

    assert Config.telegram_bot("sales")["agent"] == "other"

    assert {:ok, _} = ManageChannel.run(%{"action" => "disable", "name" => "sales"}, ctx())
    assert Config.telegram_bot("sales")["enabled"] == false

    assert {:ok, _} = ManageChannel.run(%{"action" => "remove", "name" => "sales"}, ctx())
    refute Config.telegram_bot("sales")
  end

  test "set_trainers accepts *, none and id lists" do
    ManageChannel.run(
      %{"action" => "add", "name" => "sales", "token_env" => "T", "agent" => "sales-bot"},
      ctx()
    )

    assert {:ok, _} =
             ManageChannel.run(
               %{"action" => "set_trainers", "name" => "sales", "trainers" => "none"},
               ctx()
             )

    assert Config.telegram_bot("sales")["trainers"] == []

    assert {:ok, _} =
             ManageChannel.run(
               %{"action" => "set_trainers", "name" => "sales", "trainers" => "111, 222"},
               ctx()
             )

    assert Config.telegram_bot("sales")["trainers"] == [111, 222]

    assert {:ok, _} =
             ManageChannel.run(
               %{"action" => "set_trainers", "name" => "sales", "trainers" => "*"},
               ctx()
             )

    assert Config.telegram_bot("sales")["trainers"] == ["*"]
  end

  test "set_heartbeat enables/tunes and disables the proactive check-in" do
    ManageChannel.run(
      %{"action" => "add", "name" => "sales", "token_env" => "T", "agent" => "sales-bot"},
      ctx()
    )

    assert {:ok, msg} =
             ManageChannel.run(
               %{
                 "action" => "set_heartbeat",
                 "name" => "sales",
                 "heartbeat_minutes" => 30,
                 "heartbeat_hours" => "8-22"
               },
               ctx()
             )

    assert msg =~ "every 30min"
    bot = Config.telegram_bot("sales")
    assert bot["heartbeat_minutes"] == 30
    assert bot["heartbeat_active_hours"] == [8, 22]

    assert {:ok, msg2} =
             ManageChannel.run(
               %{"action" => "set_heartbeat", "name" => "sales", "heartbeat_minutes" => 0},
               ctx()
             )

    assert msg2 =~ "disabled"
    refute Config.telegram_bot("sales")["heartbeat_minutes"]
  end

  test "list shows configured bots" do
    ManageChannel.run(
      %{"action" => "add", "name" => "sales", "token_env" => "T", "agent" => "sales-bot"},
      ctx()
    )

    assert {:ok, listing} = ManageChannel.run(%{"action" => "list"}, ctx())
    assert listing =~ "sales"
    assert listing =~ "sales-bot"
  end
end
