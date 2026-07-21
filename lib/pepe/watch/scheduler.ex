defmodule Pepe.Watch.Scheduler do
  @moduledoc """
  The in-app timer that drives watches. Ticks on a short interval and, for each
  **due** watch, runs one check off-process; a watch that fires is delivered and
  stops.

  Like the cron scheduler, it's a plain in-process ticker (no OS crontab) that only
  runs while a long-lived surface is up (`serve`/`gateway`). Two guarantees:

    * **At-most-once fire** - the updated (often `done`) watch is persisted *before*
      delivery is attempted, so a crash between firing and delivering can't re-check
      and re-fire; only the delivery is retried.
    * **Deliver-when-reachable** - a watch that fired but couldn't be delivered holds
      its message in `pending_delivery`; every tick re-attempts delivery (without
      re-checking) until it lands.

  An in-flight guard skips a watch already being checked, so a slow check (a probe or
  an agent turn) never overlaps itself.
  """

  use GenServer
  require Logger

  alias Pepe.Config
  alias Pepe.Watch
  alias Pepe.Watch.Delivery

  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Pepe.Config.Journal.put_source("watch")
    schedule_tick()
    {:ok, %{busy: MapSet.new(), refs: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)
    state = Enum.reduce(Config.watches(), state, &maybe_run(&1, &2, now))
    schedule_tick()
    {:noreply, state}
  end

  # A check/delivery task ended, however it ended (a plain finish, a crash, an exit) -
  # clear the in-flight guard. Monitored (not a bare `Task.start` + self-reported
  # `{:done, id}`) so a task that dies partway through - Delivery.deliver/2 raising, the
  # process being killed on shutdown - still releases its watch instead of leaving it
  # stuck "in flight" forever, the same fix already applied to Pepe.Cron.Scheduler.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} -> {:noreply, state}
      {id, refs} -> {:noreply, %{state | refs: refs, busy: MapSet.delete(state.busy, id)}}
    end
  end

  defp maybe_run(watch, state, now) do
    cond do
      MapSet.member?(state.busy, watch.id) ->
        state

      Watch.due?(watch, now) ->
        start(watch, state, &run_check/1)

      # Fired earlier but the channel was down - retry only the delivery.
      watch.pending_delivery ->
        start(watch, state, &run_retry/1)

      true ->
        state
    end
  end

  # Supervised (not a bare Task.start) so a graceful shutdown can see and drain in-flight
  # checks/deliveries instead of the VM just killing them - see Pepe.Application.prep_stop/1.
  # Monitored so the in-flight guard is released by the run ending, whatever ending it gets.
  defp start(watch, state, fun) do
    case Task.Supervisor.start_child(Pepe.Watch.TaskSupervisor, fn -> fun.(watch) end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | busy: MapSet.put(state.busy, watch.id), refs: Map.put(state.refs, ref, watch.id)}

      _ ->
        Logger.warning("watch #{watch.id}: could not start the run")
        state
    end
  end

  defp run_check(watch) do
    Pepe.Config.Journal.put_source("watch")
    {updated, text} = Watch.evaluate(watch)
    # Persist the new state (e.g. `done`) BEFORE delivering - at-most-once fire.
    Config.put_watch(updated)
    if text, do: deliver(updated, text)
  end

  defp run_retry(watch) do
    Pepe.Config.Journal.put_source("watch")
    deliver(watch, watch.pending_delivery)
  end

  # Deliver, recording the outcome: cleared on success, held for retry on failure.
  defp deliver(watch, text) do
    case Delivery.deliver(watch.origin, text) do
      :ok ->
        if watch.pending_delivery, do: Config.put_watch(%{watch | pending_delivery: nil})

      {:error, reason} ->
        Logger.debug("[watch] #{watch.id} delivery deferred: #{inspect(reason)}")
        Config.put_watch(%{watch | pending_delivery: text})
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
