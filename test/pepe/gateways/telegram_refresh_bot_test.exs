defmodule Pepe.Gateways.TelegramRefreshBotTest do
  @moduledoc """
  `refresh_bot/0` runs at the top of every poll and must never crash the poller on a bad config
  read (a hand-edit gone wrong, a truncated write) - it keeps the last-known-good snapshot instead.
  But that used to fail silently; a persistently broken config could go unnoticed indefinitely
  while the bot quietly ran stale. It's logged now.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Pepe.Gateways.Telegram

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_refreshbot_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "a corrupt config.json is logged, and refresh_bot/0 returns normally rather than crashing", %{home: home} do
    File.write!(Path.join(home, "config.json"), "{not valid json")

    log = capture_log(fn -> assert Telegram.refresh_bot() == :ok end)
    assert log =~ "[telegram] refresh_bot failed for default"
  end

  test "a healthy config logs nothing" do
    Pepe.Config.put_telegram(%{"name" => "default", "bot_token" => "t"})

    log = capture_log(fn -> Telegram.refresh_bot() end)
    refute log =~ "refresh_bot failed"
  end
end
