defmodule Pepe.Usage.Trends do
  @moduledoc """
  The numbers behind the dashboard's charts: how this week (or month) is going against the
  one before it, and how runs and errors move week by week.

  Two honest choices worth knowing:

    * A comparison is **so far against the same point of the previous period**, not against
      the previous period in full. On a Wednesday, "this week" is Monday to now and "last
      week" is Monday to Wednesday at the same hour, otherwise every Monday would read as a
      collapse.
    * A *run* is one agent turn (one `Pepe.Trace`), an *error* is a run that did not end
      `ok`. They are not the model-call count the usage ledger keeps: one run can make
      several calls.

  Scope is the same as `Pepe.Usage.summary/3`: `:all`, a project slug, a list of slugs, or
  `nil` for the default project.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Trace.Trace
  alias Pepe.Usage

  @periods [:week, :month]

  @typedoc "Totals for one window."
  @type window :: %{
          from: integer(),
          to: integer(),
          tokens: integer(),
          calls: integer(),
          cost: float(),
          billable: float(),
          runs: integer(),
          errors: integer(),
          success: float() | nil,
          ms: integer() | nil,
          cached_share: float() | nil,
          saved: float()
        }

  @doc """
  Compare the current `period` (`:week` or `:month`) so far with the same stretch of the
  previous one.

  Returns `%{period, current, previous, change, currency}`. `change` holds, per metric, the
  percentage move (`nil` when the previous window had nothing to divide by).
  """
  @spec compare(term(), :week | :month, keyword()) :: map()
  def compare(scope, period, opts \\ []) when period in @periods do
    tz = opts[:tz] || Config.default_timezone()
    now = opts[:now] || System.system_time(:second)

    {cur_from, prev_from, prev_to} = windows(period, now, tz)

    current = window(scope, cur_from, now + 1, tz)
    previous = window(scope, prev_from, prev_to, tz)

    %{
      period: period,
      current: current,
      previous: previous,
      change:
        [:tokens, :calls, :billable, :runs, :errors, :ms, :saved]
        |> Map.new(&{&1, percent(current[&1], previous[&1])})
        # A rate moves in points (94% to 96% is 2 points), not in percent of itself.
        |> Map.merge(%{
          success: points(current.success, previous.success),
          cached_share: points(current.cached_share, previous.cached_share)
        }),
      currency: Config.currency()
    }
  end

  @doc """
  The last `count` weeks (oldest first, the running one last) with, per week, the runs,
  errors, tokens and billable amount. Weeks with no activity are present with zeros, so a
  chart's x axis has no holes.
  """
  @spec weekly(term(), pos_integer(), keyword()) :: [map()]
  def weekly(scope, count \\ 8, opts \\ []) when is_integer(count) and count > 0 do
    tz = opts[:tz] || Config.default_timezone()
    now = opts[:now] || System.system_time(:second)

    this_monday = local_monday(now, tz)
    mondays = for back <- (count - 1)..0//-1, do: Date.add(this_monday, -7 * back)
    from_at = mondays |> hd() |> start_of_day(tz)

    runs =
      scope
      |> trace_rows(from_at, now + 1)
      |> Enum.group_by(fn row -> row.at |> local_date(tz) |> Date.beginning_of_week() end)

    usage =
      scope
      |> Usage.summary(:week, tz: tz, from: from_at, to: now + 1, limit: count)
      |> Map.fetch!(:buckets)
      |> Map.new(&{&1.key, &1})

    Enum.map(mondays, fn monday ->
      rows = Map.get(runs, monday, [])
      bucket = Map.get(usage, Date.to_iso8601(monday), %{})

      %{
        key: Date.to_iso8601(monday),
        runs: length(rows),
        errors: Enum.count(rows, &(not &1.ok?)),
        success: success_rate(rows),
        ms: median(Enum.map(rows, & &1.ms)),
        tokens: Map.get(bucket, :total, 0),
        billable: Map.get(bucket, :billable, 0.0),
        cached_share: share(Map.get(bucket, :cached, 0), Map.get(bucket, :in, 0)),
        saved: Map.get(bucket, :saved, 0.0)
      }
    end)
  end

  @doc """
  Where the last `days` days of runs went: how many started in each hour of the day
  (`:hours`, 24 counts from midnight), and the most used channels (`:sources`) and agents
  (`:agents`) as `{name, runs}`, busiest first, at most `limit` of each.
  """
  @spec activity(term(), pos_integer(), keyword()) :: %{
          hours: [non_neg_integer()],
          sources: [{String.t(), non_neg_integer()}],
          agents: [{String.t(), non_neg_integer()}]
        }
  def activity(scope, days \\ 30, opts \\ []) do
    tz = opts[:tz] || Config.default_timezone()
    now = opts[:now] || System.system_time(:second)
    limit = opts[:limit] || 6
    rows = trace_rows(scope, now - days * 86_400, now + 1)

    by_hour = Enum.frequencies_by(rows, fn row -> row.at |> DateTime.from_unix!() |> DateTime.shift_zone!(tz) |> Map.fetch!(:hour) end)

    %{
      hours: for(h <- 0..23, do: Map.get(by_hour, h, 0)),
      sources: top(rows, & &1.source, limit),
      agents: top(rows, & &1.agent, limit)
    }
  end

  defp top(rows, key, limit) do
    rows
    |> Enum.frequencies_by(key)
    |> Enum.reject(fn {name, _n} -> name in [nil, ""] end)
    |> Enum.sort_by(fn {name, n} -> {-n, name} end)
    |> Enum.take(limit)
  end

  ###
  ### windows
  ###

  # {start of the current period, start of the previous one, the previous one's end at the same
  # elapsed point}. The end is clamped to the previous period's own end: the 31st of a month
  # has no counterpart in a 30-day one.
  defp windows(:week, now, tz) do
    cur = now |> local_monday(tz) |> start_of_day(tz)
    prev = now |> local_monday(tz) |> Date.add(-7) |> start_of_day(tz)
    {cur, prev, min(prev + (now - cur) + 1, cur)}
  end

  defp windows(:month, now, tz) do
    today = local_date(now, tz)
    cur = today |> Date.beginning_of_month() |> start_of_day(tz)
    prev = today |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month() |> start_of_day(tz)
    {cur, prev, min(prev + (now - cur) + 1, cur)}
  end

  defp window(scope, from_at, to_at, tz) do
    totals = Map.fetch!(Usage.summary(scope, :day, tz: tz, from: from_at, to: to_at, limit: 1), :totals)
    rows = trace_rows(scope, from_at, to_at)

    %{
      from: from_at,
      to: to_at,
      tokens: totals.total,
      calls: totals.count,
      cost: totals.cost,
      billable: totals.billable,
      runs: length(rows),
      errors: Enum.count(rows, &(not &1.ok?)),
      success: success_rate(rows),
      ms: median(Enum.map(rows, & &1.ms)),
      cached_share: share(totals.cached, totals.in),
      saved: totals.saved
    }
  end

  defp success_rate([]), do: nil
  defp success_rate(rows), do: Float.round(Enum.count(rows, & &1.ok?) / length(rows) * 100, 1)

  defp share(_part, whole) when whole in [0, nil], do: nil
  defp share(part, whole), do: Float.round(part / whole * 100, 1)

  # The middle run, not the average: one stuck five-minute run should not make a good week read slow.
  defp median(values) do
    case values |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] ->
        nil

      sorted ->
        mid = div(length(sorted), 2)
        if rem(length(sorted), 2) == 1, do: Enum.at(sorted, mid), else: round((Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2)
    end
  end

  ###
  ### traces
  ###

  # One small map per run in `[from_at, to_at)`: a few columns, not the events stream.
  defp trace_rows(scope, from_at, to_at) do
    query =
      from(t in Trace,
        where: t.at >= ^from_at and t.at < ^to_at,
        select: {t.at, fragment("json_extract(?, '$.kind')", t.outcome), t.ms, t.source, t.agent}
      )

    query
    |> scoped(scope)
    |> Repo.all()
    |> Enum.map(fn {at, kind, ms, source, agent} -> %{at: at, ok?: kind == "ok", ms: ms, source: source, agent: agent} end)
  end

  defp scoped(query, scope) when scope in [:all, "all"], do: query
  defp scoped(query, scopes) when is_list(scopes), do: from(t in query, where: t.scope in ^scopes)

  defp scoped(query, scope) do
    name = if scope in [nil, ""], do: Config.default_project_slug(), else: to_string(scope)
    from(t in query, where: t.scope == ^name)
  end

  ###
  ### time
  ###

  defp local_date(at, tz) do
    at |> DateTime.from_unix!() |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  defp local_monday(at, tz), do: at |> local_date(tz) |> Date.beginning_of_week()

  # Midnight can be skipped or repeated by a clock change: take the later reading of a repeat
  # and the first instant after a gap, rather than crash a dashboard page over it.
  defp start_of_day(%Date{} = date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> DateTime.to_unix(dt)
      {:ambiguous, _first, second} -> DateTime.to_unix(second)
      {:gap, _before, just_after} -> DateTime.to_unix(just_after)
    end
  end

  defp percent(current, previous) when is_nil(current) or previous in [nil, 0, +0.0, -0.0], do: nil
  defp percent(current, previous), do: Float.round((current - previous) / previous * 100, 1)

  defp points(current, previous) when is_nil(current) or is_nil(previous), do: nil
  defp points(current, previous), do: Float.round(current - previous, 1)
end
