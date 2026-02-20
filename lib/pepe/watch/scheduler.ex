defmodule Pepe.Watch.Scheduler do
  @moduledoc """
  The in-app timer that drives watches. Ticks on a short interval and, for each
  **due** watch, runs one check off-process; a watch that fires is delivered and
  stops.

  Like the cron scheduler, it's a plain in-process ticker (no OS crontab) that only
  runs while a long-lived surface is up (`serve`/`gateway`). Two guarantees:

    * **At-most-once fire** — the updated (often `done`) watch is persisted *before*
      delivery is attempted, so a crash between firing and delivering can't re-check
      and re-fire; only the delivery is retried.
    * **Deliver-when-reachable** — a watch that fired but couldn't be delivered holds
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
    schedule_tick()
    {:ok, %{busy: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)
    busy = Enum.reduce(Config.watches(), state.busy, &maybe_run(&1, &2, now))
    schedule_tick()
    {:noreply, %{state | busy: busy}}
  end

  # A check/delivery task finished for this watch id — clear the in-flight guard.
  def handle_info({:done, id}, state),
    do: {:noreply, %{state | busy: MapSet.delete(state.busy, id)}}

  defp maybe_run(watch, busy, now) do
    cond do
      MapSet.member?(busy, watch.id) ->
        busy

      Watch.due?(watch, now) ->
        run_check(watch)
        MapSet.put(busy, watch.id)

      # Fired earlier but the channel was down — retry only the delivery.
      watch.pending_delivery ->
        run_retry(watch)
        MapSet.put(busy, watch.id)

      true ->
        busy
    end
  end

  defp run_check(watch) do
    parent = self()

    Task.start(fn ->
      {updated, text} = Watch.evaluate(watch)
      # Persist the new state (e.g. `done`) BEFORE delivering — at-most-once fire.
      Config.put_watch(updated)
      if text, do: deliver(updated, text)
      send(parent, {:done, watch.id})
    end)
  end

  defp run_retry(watch) do
    parent = self()

    Task.start(fn ->
      deliver(watch, watch.pending_delivery)
      send(parent, {:done, watch.id})
    end)
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
