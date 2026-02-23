defmodule Pepe.Cron do
  @moduledoc """
  Runs a single scheduled task and delivers its result.

  A cron fires in a **fresh, stateless run** (`Pepe.Agent.oneshot/3`) - it carries
  no chat history, which is why the stored `prompt` must be self-contained. The
  result is delivered to the cron's `deliver` target (a Telegram chat, or the log).

  Schedule matching and next-run computation go through `crontab`; timezones through
  the configured `tz` database, so `"America/Sao_Paulo"`, `"Europe/Berlin"`, etc. all
  resolve without anything being hard-coded.
  """

  require Logger

  alias Pepe.Config
  alias Pepe.Config.Cron
  alias Crontab.CronExpression.Parser
  alias Crontab.DateChecker
  alias Crontab.Scheduler

  @doc "Parse a cron expression string, e.g. `\"0 8 * * *\"`."
  @spec parse(String.t()) :: {:ok, Crontab.CronExpression.t()} | {:error, term()}
  def parse(schedule) when is_binary(schedule), do: Parser.parse(schedule)

  @doc "Is `cron` due at `naive_dt` (a NaiveDateTime already in the cron's timezone)?"
  @spec due?(Cron.t(), NaiveDateTime.t()) :: boolean()
  def due?(%Cron{schedule: schedule}, %NaiveDateTime{} = naive_dt) do
    case parse(schedule) do
      {:ok, expr} -> DateChecker.matches_date?(expr, naive_dt)
      {:error, _} -> false
    end
  end

  @doc """
  Next fire time as a `DateTime` in the cron's own timezone (for display), or nil
  when the schedule can't be parsed.
  """
  @spec next_run(Cron.t()) :: DateTime.t() | nil
  def next_run(%Cron{schedule: schedule, timezone: tz}) do
    with {:ok, expr} <- parse(schedule),
         {:ok, now} <- DateTime.now(tz),
         {:ok, naive} <- Scheduler.get_next_run_date(expr, DateTime.to_naive(now)) do
      case DateTime.from_naive(naive, tz) do
        {:ok, dt} -> dt
        # Skip forward through a DST gap / pick the later side of an overlap.
        {:ambiguous, _first, later} -> later
        {:gap, _just_before, just_after} -> just_after
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc """
  Catch-up: did this cron **miss** a firing (server was down/asleep at the scheduled
  time)? True when the most recent scheduled time passed without a run and we're
  still inside the grace window - half the job's period, clamped to 2min-2h. Used by
  the scheduler to fire a missed job ONCE on recovery, anchored to `last_run`.
  Returns `{true, missed_time_iso}` or `false`.
  """
  @spec missed?(Cron.t()) :: {true, String.t()} | false
  def missed?(%Cron{schedule: schedule, timezone: tz, last_run: last_run}) do
    with {:ok, expr} <- parse(schedule),
         {:ok, now} <- DateTime.now(tz),
         naive = DateTime.to_naive(now),
         {:ok, prev} <- Crontab.Scheduler.get_previous_run_date(expr, naive),
         {:ok, next} <- Scheduler.get_next_run_date(expr, naive),
         {:ok, prev_dt} <- from_naive(prev, tz) do
      period = NaiveDateTime.diff(next, prev)
      grace = period |> div(2) |> max(120) |> min(7200)
      overdue = DateTime.diff(now, prev_dt)
      prev_unix = DateTime.to_unix(prev_dt)

      # Never ran, or last run predates the missed slot - and we're within grace.
      if (last_run || 0) < prev_unix and overdue > 0 and overdue <= grace do
        {true, NaiveDateTime.to_iso8601(prev)}
      else
        false
      end
    else
      _ -> false
    end
  end

  defp from_naive(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, dt}
      {:ambiguous, _first, later} -> {:ok, later}
      {:gap, _before, just_after} -> {:ok, just_after}
      other -> other
    end
  end

  @doc """
  Run a cron now: execute the agent on the stored prompt in a fresh session, record
  the outcome (both `last_result` and the append-only run log), and deliver it.

  `source` is `:scheduler` (fired by the timer), `:manual` (forced from the CLI or
  dashboard) or `:agent` (forced from a chat). Returns `{:ok, output}` or
  `{:error, reason}`.
  """
  @spec run(Cron.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def run(cron, source \\ :manual)

  def run(%Cron{} = cron, source) do
    Config.put_locale()
    opts = if cron.model, do: [model: Config.get_model(cron.model)], else: []

    case Pepe.Agent.oneshot(cron.agent, cron.prompt, opts) do
      {:ok, output, _messages} ->
        record(cron, source, true, output)
        deliver(cron.deliver, format(cron, output))
        {:ok, output}

      {:error, reason} ->
        Logger.warning("cron #{cron.id} failed: #{inspect(reason)}")
        record(cron, source, false, "⚠️ error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Deliver `text` to a target string: `"telegram:<chat_id>"` sends to that chat,
  `"none"` sends nowhere (the run is still recorded in the history), anything else
  goes to the app log.
  """
  def deliver("telegram:" <> chat_id, text) do
    Pepe.Gateways.Telegram.deliver(chat_id, text)
  end

  def deliver("none", _text), do: :ok

  def deliver(_log_or_unknown, text) do
    Logger.info("[cron] #{text}")
    :ok
  end

  # Prefix delivered output with the task name so a chat receiving several crons
  # can tell them apart.
  defp format(%Cron{name: name}, output) when is_binary(name) and name != "",
    do: "🕒 #{name}\n\n#{output}"

  defp format(_cron, output), do: output

  defp record(%Cron{} = cron, source, ok?, output) do
    Config.put_cron(%{cron | last_run: System.system_time(:second), last_result: clip(output)})
    Pepe.Cron.Log.append(cron.id, source, ok?, output)
  end

  # Keep last_result small in the config file.
  defp clip(text) when is_binary(text) do
    if String.length(text) > 2000, do: String.slice(text, 0, 2000) <> "...", else: text
  end

  defp clip(text), do: to_string(text)
end
