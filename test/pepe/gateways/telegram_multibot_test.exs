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
