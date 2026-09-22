defmodule Pepe.Gateways.DiscordWatchdog do
  @moduledoc """
  Notices when `Pepe.Gateways.DiscordSupervisor` goes down - most often by exhausting its
  own restart budget (a connection crash-looping five times within a minute) - and says so
  with the rest of the app's own `[discord]` logging, instead of leaving it to whatever the
  OTP supervisor report looks like on this run's `:logger` config.

  `Pepe.Gateways.DiscordSupervisor` is registered `:transient` under
  `Pepe.Gateways.Supervisor` on purpose: exhausting its budget must not also spend the
  parent's, or a crash-looping Discord connection would take Telegram down with it. That
  isolation is exactly why nothing already logs this - the exit is contained by design, so
  only something watching from outside ever sees it happen.

  Must be listed *after* `DiscordSupervisor` in `Pepe.Gateways.Supervisor`'s children: a
  plain `one_for_one` supervisor starts children in list order and stops them in reverse,
  so this process is already watching by the time `DiscordSupervisor` could go down, and is
  already gone (with nothing left to log) by the time an ordinary `mix pepe serve` shutdown
  reaches `DiscordSupervisor` - it never mistakes a normal stop for the supervisor giving up.
  """
  use GenServer

  require Logger

  @doc "Start, watching `target` (a registered name or a pid - a raw pid is how a test aims this at a stand-in)."
  def start_link(target), do: GenServer.start_link(__MODULE__, target)

  @impl true
  def init(target) do
    watch(target)
    {:ok, nil}
  end

  defp watch(pid) when is_pid(pid), do: Process.monitor(pid)

  defp watch(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> Logger.warning("[discord] no #{inspect(name)} to watch at startup")
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) when reason != :normal do
    Logger.error(
      "[discord] the gateway supervisor is down (#{inspect(reason)}), most likely from exhausting its own " <>
        "restart budget; every Discord channel-message connection is unavailable until reload_discord/0 restarts it"
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}
end
