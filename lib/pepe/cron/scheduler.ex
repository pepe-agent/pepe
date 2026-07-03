defmodule Pepe.Cron.Scheduler do
  @moduledoc """
  The in-app cron timer. Ticks on a short interval and fires any enabled cron whose
  schedule matches the current minute *in that cron's own timezone*.

  This is a plain in-process ticker - no OS crontab - like a `setInterval` loop or a
  `croniter`-driven scheduler in other runtimes. It only
  runs while a long-running surface is up (`mix pepe serve` / `gateway`); one-shot
  CLI commands never start it, so they can't fire jobs.

  Each cron fires at most once per minute: a per-job "last fired minute" guard
  (keyed in that job's timezone) survives clock drift and the sub-minute tick.

  ## A job does not run on top of itself

  A cron here is not an idempotent shell script, it is **an agent turn**. It costs a model
  call, it has side effects (a message sent, a file written), and every run of the same cron
  shares one agent workspace. So a job that takes seven minutes on a five-minute schedule
  must not pile up: two runs, then three, then four, each one billed, the report delivered
  twice, and two runs writing over each other in the same workspace. You would find out from
  the invoice.

  So a due job whose previous run is still going is **skipped**, and never silently: the skip
  is written to that cron's run log, which is what tells you the job is outgrowing its own
  schedule, and that is the fact worth knowing. Set `"overlap": true` on a cron that genuinely
  wants concurrency.

  The claim is released by the monitor's `:DOWN`, deliberately. A message that arrives however
  the run ends, including a crash or a wedge, is the only kind of release worth having: a
  cleanup that runs at the end of the job never runs for the job that never reaches its end,
  and then the job is marked in-flight forever and quietly stops firing.
  """

  use GenServer
  require Logger

  alias Pepe.Config
  alias Pepe.Cron

  # Sub-minute so we never miss a minute even with drift; the per-job guard dedupes.
  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{fired: %{}, price_check: 0, budget_check: 0, running: %{}, refs: %{}}}
  end

  @doc "The crons that have a run in flight right now (used by the dashboard and by tests)."
  def running, do: GenServer.call(__MODULE__, :running)

  @impl true
  def handle_call(:running, _from, state), do: {:reply, Map.keys(state.running), state}

  @impl true
  def handle_info(:tick, state) do
    state = Enum.reduce(Config.crons(), state, &maybe_fire/2)
    schedule_tick()

    {:noreply,
     %{
       state
       | price_check: maybe_refresh_prices(state.price_check),
         budget_check: maybe_budget_check(state.budget_check)
     }}
  end

  # The run ended, however it ended. This is the only place the in-flight claim is released,
  # and it is a message rather than a callback for exactly that reason: a run that crashes,
  # hangs and is killed, or is drained at shutdown still gets here, and a job whose claim is
  # never released is a job that silently never fires again.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} -> {:noreply, state}
      {id, refs} -> {:noreply, %{state | refs: refs, running: Map.delete(state.running, id)}}
    end
  end

  # Piggyback the weekly billing price-cache refresh on the tick - attempted at most
  # hourly, and only here (this scheduler runs only while a server surface is up).
  # `Pepe.Pricing` no-ops unless the cache is actually stale.
  defp maybe_refresh_prices(next_at) do
    now = System.system_time(:second)

    if now >= next_at do
      Task.start(&Pepe.Pricing.maybe_auto_refresh/0)
      now + 3600
    else
      next_at
    end
  end

  # Piggyback the soft budget-alert sweep on the tick, at most once a minute. Channel-agnostic: the
  # alert reaches each active session on its own channel (see Pepe.Budget.Alert). Off-process so a
  # slow delivery never stalls the scheduler.
  defp maybe_budget_check(next_at) do
    now = System.system_time(:second)

    if now >= next_at do
      Task.start(&Pepe.Budget.Alert.check/0)
      now + 60
    else
      next_at
    end
  end

  # Disabled jobs never fire; enabled jobs fire once per matching minute.
  defp maybe_fire(%{enabled: false}, state), do: state

  defp maybe_fire(cron, state) do
    case minute_key(cron.timezone) do
      {:ok, naive, key} ->
        cond do
          Cron.due?(cron, naive) and state.fired[cron.id] != key ->
            claim(cron, key, state)

          # Catch-up: the scheduled time passed while we were down - fire once,
          # deduped on the missed slot so one recovery never double-fires.
          catchup = catch_up_key(cron, state.fired) ->
            claim(cron, catchup, state)

          true ->
            state
        end

      :error ->
        Logger.warning("cron #{cron.id}: unknown timezone #{inspect(cron.timezone)}")
        state
    end
  end

  # The slot is marked fired either way, so a skip is reported once for the slot it belongs
  # to rather than on every tick inside that minute.
  defp claim(cron, key, state) do
    state = %{state | fired: Map.put(state.fired, cron.id, key)}

    cond do
      not Map.has_key?(state.running, cron.id) -> start(cron, state)
      cron.overlap -> start(cron, state)
      true -> skip(cron, state)
    end
  end

  # It is due, and it is still running the last one. Saying nothing here is the failure that
  # matters: the job would simply stop happening, on schedule, and the first sign of it would
  # be that whatever it was supposed to do stopped being done.
  defp skip(cron, state) do
    Logger.warning("cron #{cron.id} is due and the previous run is still going; skipping this one")
    Cron.skipped(cron)
    state
  end

  # Supervised (not a bare Task.start) so a graceful shutdown can see and drain
  # in-flight jobs instead of just killing them with the VM - see
  # Pepe.Application.prep_stop/1. Monitored so the in-flight claim is released by the run
  # ending, whatever ending it gets.
  defp start(cron, state) do
    case Task.Supervisor.start_child(Pepe.Cron.TaskSupervisor, fn -> Cron.run(cron, :scheduler) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        %{
          state
          | running: Map.put(state.running, cron.id, ref),
            refs: Map.put(state.refs, ref, cron.id)
        }

      _ ->
        Logger.warning("cron #{cron.id}: could not start the run")
        state
    end
  end

  defp catch_up_key(cron, fired) do
    case Cron.missed?(cron) do
      {true, slot} ->
        key = "catchup:" <> slot
        if fired[cron.id] == key, do: nil, else: key

      false ->
        nil
    end
  end

  # Current time in `tz`, truncated to the minute, plus a stable per-minute key.
  defp minute_key(tz) do
    case DateTime.now(tz) do
      {:ok, dt} ->
        naive = dt |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
        naive = %{naive | second: 0}
        {:ok, naive, NaiveDateTime.to_iso8601(naive)}

      _ ->
        :error
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
