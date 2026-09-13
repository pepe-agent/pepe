defmodule Pepe.Insight.Scheduler do
  @moduledoc """
  The in-app timer that drives a spec's `retrain_interval_s` - mirrors
  `Pepe.Watch.Scheduler`'s shape exactly (in-flight guard, monitored `Task.Supervisor`
  children, best-effort, never crashes on a bad fit).

  Coarser than `Watch.Scheduler`'s 30s (`@tick_ms 60_000`): retraining is real work, not a
  cheap check, and no retrain interval anyone would set needs sub-minute precision.

  Two gates before a fit actually runs, checked in order:

    1. `Pepe.Insight.due_specs/1` - has `retrain_interval_s` elapsed since the last train?
    2. `Pepe.Insight.Source.row_count/2` - have at least `min_new_rows` new rows arrived
       since `row_count_at_last_train`? This is what makes an `"import"`-sourced spec
       schedulable at all (nothing else would tell it "how much has changed"), and it's
       what stops a `"db"`-sourced spec from re-fitting on the exact same rows every tick
       just because the interval elapsed with no new data.

  A spec that passes both retrains via the ordinary `Pepe.Insight.train_now/3` path - same
  code a conversational `train_now` call runs, so there is only one training code path to
  keep correct, not two.
  """

  use GenServer

  require Logger

  alias Pepe.Insight
  alias Pepe.Insight.Source
  alias Pepe.Scheduler.Guard

  @tick_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Pepe.Config.Journal.put_source("insight")
    # A spec still "training" at boot can only mean the run that set it was interrupted (a
    # kill, a crash, a restart) - nothing else holds that status across a process lifetime.
    Insight.reconcile_stuck_training()
    schedule_tick()
    {:ok, %{guard: Guard.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)
    state = Enum.reduce(Insight.due_specs(now), state, &maybe_retrain(&1, &2))
    schedule_tick()
    {:noreply, state}
  end

  # A retrain task ended, however it ended - clear the in-flight guard. Monitored (not a
  # bare Task.start) so a task that dies partway through still releases its spec instead of
  # leaving it stuck "in flight" forever, same fix as Pepe.Watch.Scheduler/Pepe.Cron.Scheduler.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Guard.down(state.guard, ref) do
      :not_found -> {:noreply, state}
      {_id, _payload, guard} -> {:noreply, %{state | guard: guard}}
    end
  end

  defp maybe_retrain(spec, state) do
    if Guard.busy?(state.guard, spec.id) do
      state
    else
      guard = Guard.start(state.guard, Pepe.Insight.TaskSupervisor, spec.id, fn -> run(spec) end, "insight")
      %{state | guard: guard}
    end
  end

  defp run(spec) do
    Pepe.Config.Journal.put_source("insight")

    # An agent can be renamed or deleted after a spec is defined against it (nothing today
    # re-points or removes an orphaned spec on rename/delete, matching every other
    # Repo-backed per-agent subsystem - Watch/Board/Graph/Commitments have the same gap).
    # Skipping here, rather than resolving ctx.agent to nil, avoids the alternative: a "db"
    # spec's tenant_binding crashing this scheduler with an opaque error on every tick.
    case Pepe.Config.get_agent(spec.agent) do
      nil ->
        Logger.warning("insight #{spec.id}: agent #{inspect(spec.agent)} no longer exists, skipping retrain")

      agent ->
        maybe_train(spec, %{agent: agent})
    end
  end

  defp maybe_train(spec, ctx) do
    case Source.row_count(spec, ctx) do
      {:ok, count} when count - spec.row_count_at_last_train >= spec.min_new_rows ->
        Insight.train_now(spec.agent, spec.name, ctx)

      _ ->
        :ok
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
