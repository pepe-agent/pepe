defmodule Pepe.Skills.Curator.Scheduler do
  @moduledoc """
  The in-app timer that lets `Pepe.Skills.Curator` run on its own, same shape as
  `Pepe.Insight.Scheduler` (in-flight guard, monitored `Task.Supervisor` child, never
  crashes on a failed run).

  It only asks a question on each tick, `Pepe.Skills.Curator.due/1`: enabled, not paused,
  the interval elapsed, and nothing said in any conversation for `min_idle_hours`. The tick is
  coarse on purpose (the curator's own interval is hours to days, and the checks before the
  idle one are a config read and a small file).
  """

  use GenServer

  require Logger

  alias Pepe.Scheduler.Guard
  alias Pepe.Skills.Curator

  @tick_ms 600_000
  @id "skill-curator"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{guard: Guard.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = maybe_run(state)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Guard.down(state.guard, ref) do
      :not_found -> {:noreply, state}
      {_id, _payload, guard} -> {:noreply, %{state | guard: guard}}
    end
  end

  defp maybe_run(state) do
    if not Guard.busy?(state.guard, @id) and Curator.due() == :run do
      guard = Guard.start(state.guard, Pepe.Skills.Curator.TaskSupervisor, @id, &run/0, "skill-curator")
      %{state | guard: guard}
    else
      state
    end
  end

  defp run do
    {:ok, report} = Curator.run()
    Logger.info("[skills] curator: #{report["summary"]}")
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
