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
    {:ok, %{fired: %{}, price_check: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    fired = Enum.reduce(Config.crons(), state.fired, &maybe_fire/2)
    price_check = maybe_refresh_prices(state.price_check)
    schedule_tick()
    {:noreply, %{state | fired: fired, price_check: price_check}}
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

  # Disabled jobs never fire; enabled jobs fire once per matching minute.
  defp maybe_fire(%{enabled: false}, fired), do: fired

  defp maybe_fire(cron, fired) do
    case minute_key(cron.timezone) do
      {:ok, naive, key} ->
        cond do
          Cron.due?(cron, naive) and fired[cron.id] != key ->
            fire(cron)
            Map.put(fired, cron.id, key)

          # Catch-up: the scheduled time passed while we were down - fire once,
          # deduped on the missed slot so one recovery never double-fires.
          catchup = catch_up_key(cron, fired) ->
            fire(cron)
            Map.put(fired, cron.id, catchup)

          true ->
            fired
        end

      :error ->
        Logger.warning("cron #{cron.id}: unknown timezone #{inspect(cron.timezone)}")
        fired
    end
  end

  # Supervised (not a bare Task.start) so a graceful shutdown can see and drain
  # in-flight jobs instead of just killing them with the VM - see
  # Pepe.Application.prep_stop/1.
  defp fire(cron) do
    Task.Supervisor.start_child(Pepe.Cron.TaskSupervisor, fn -> Cron.run(cron, :scheduler) end)
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
