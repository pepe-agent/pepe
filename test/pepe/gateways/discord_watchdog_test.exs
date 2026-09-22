defmodule Pepe.Gateways.DiscordWatchdogTest do
  @moduledoc """
  `Pepe.Gateways.DiscordSupervisor` is registered `:transient`, so a crash-looping Discord
  connection that exhausts its restart budget takes the whole subsystem down silently -
  nothing else in the tree restarts it or says so. The watchdog is the thing that notices.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pepe.Gateways.DiscordWatchdog

  test "a watched process crashing is logged as an error" do
    watched = spawn(fn -> receive do: (:die -> raise("boom")) end)

    log =
      capture_log(fn ->
        {:ok, watchdog} = start_supervised({DiscordWatchdog, watched})
        ref = Process.monitor(watched)
        send(watched, :die)
        assert_receive {:DOWN, ^ref, :process, _pid, _}, 1_000
        # The watchdog's own handling of the same :DOWN races the test process' - a synchronous
        # call blocks until every message already in its mailbox (including that :DOWN) has
        # been handled, so the log line is guaranteed to exist once this returns.
        :sys.get_state(watchdog)
      end)

    assert log =~ "[discord]"
    assert log =~ "restart budget"
  end

  test "a watched process exiting normally draws no log" do
    watched = spawn(fn -> receive do: (:die -> :ok) end)

    log =
      capture_log(fn ->
        {:ok, watchdog} = start_supervised({DiscordWatchdog, watched})
        ref = Process.monitor(watched)
        send(watched, :die)
        assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
        :sys.get_state(watchdog)
      end)

    refute log =~ "[discord]"
  end
end
