defmodule Cortex.Cron.Scheduler do
  @moduledoc """
  The in-app cron timer. Ticks on a short interval and fires any enabled cron whose
  schedule matches the current minute *in that cron's own timezone*.

  This is a plain in-process ticker — no OS crontab — like a `setInterval` loop or a
  `croniter`-driven scheduler in other runtimes. It only
  runs while a long-running surface is up (`mix cortex serve` / `gateway`); one-shot
  CLI commands never start it, so they can't fire jobs.

  Each cron fires at most once per minute: a per-job "last fired minute" guard
  (keyed in that job's timezone) survives clock drift and the sub-minute tick.
  """

  use GenServer
  require Logger

  alias Cortex.Config
  alias Cortex.Cron

  # Sub-minute so we never miss a minute even with drift; the per-job guard dedupes.
  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{fired: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    fired = Enum.reduce(Config.crons(), state.fired, &maybe_fire/2)
    schedule_tick()
    {:noreply, %{state | fired: fired}}
  end

  # Disabled jobs never fire; enabled jobs fire once per matching minute.
  defp maybe_fire(%{enabled: false}, fired), do: fired

  defp maybe_fire(cron, fired) do
    case minute_key(cron.timezone) do
      {:ok, naive, key} ->
        if Cron.due?(cron, naive) and fired[cron.id] != key do
          Task.start(fn -> Cron.run(cron, :scheduler) end)
          Map.put(fired, cron.id, key)
        else
          fired
        end

      :error ->
        Logger.warning("cron #{cron.id}: unknown timezone #{inspect(cron.timezone)}")
        fired
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
