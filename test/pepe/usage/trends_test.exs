defmodule Pepe.Usage.TrendsTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Trace.Trace
  alias Pepe.Usage.Log
  alias Pepe.Usage.Trends

  # Wednesday 30 Sep 2026, noon UTC. The week began Monday the 28th, the one before it Monday
  # the 21st, so "the same point last week" is Wednesday the 23rd at noon.
  @tz "Etc/UTC"
  @now 1_790_769_600

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_trends_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, project: Config.default_project_slug()}
  end

  defp day(day_of_month, hour, month \\ 9) do
    {:ok, dt, _} = DateTime.from_iso8601("2026-#{pad(month)}-#{pad(day_of_month)}T#{pad(hour)}:00:00Z")
    DateTime.to_unix(dt)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp usage(project, at, tokens_in),
    do: Log.append(project, %{"at" => at, "agent" => "a", "model" => "m", "in" => tokens_in, "out" => 0})

  defp run(project, at, kind, extra \\ %{}) do
    row = %{id: "#{at}-#{System.unique_integer([:positive])}", scope: project, at: at, agent: "a", outcome: %{"kind" => kind}, events: []}
    Repo.insert_all(Trace, [Map.merge(row, extra)])
  end

  test "week to date is compared with the same stretch of last week, not all of it", %{project: project} do
    usage(project, day(28, 10), 1000)
    usage(project, day(21, 10), 500)
    # Friday of last week: after the cut-off point, so it must not count against this week.
    usage(project, day(25, 9), 9000)

    run(project, day(28, 9), "ok")
    run(project, day(29, 9), "ok")
    run(project, day(29, 10), "error")
    run(project, day(21, 9), "ok")
    run(project, day(22, 9), "error")
    run(project, day(26, 9), "ok")

    result = Trends.compare(project, :week, tz: @tz, now: @now)

    assert result.current.tokens == 1000
    assert result.previous.tokens == 500
    assert result.change.tokens == 100.0

    assert {result.current.runs, result.current.errors} == {3, 1}
    assert {result.previous.runs, result.previous.errors} == {2, 1}
    assert result.change.runs == 50.0
  end

  test "a metric with nothing to compare against has no percentage", %{project: project} do
    usage(project, day(28, 10), 1000)

    assert Trends.compare(project, :week, tz: @tz, now: @now).change.tokens == nil
  end

  test "month to date uses the previous month up to the same point", %{project: project} do
    usage(project, day(3, 10), 200)
    usage(project, day(3, 10, 8), 100)
    # 31 Aug 2026 is after the cut-off (30th of Sep maps to 30th of Aug), so it is left out.
    usage(project, day(31, 10, 8), 5000)

    result = Trends.compare(project, :month, tz: @tz, now: @now)

    assert result.current.tokens == 200
    assert result.previous.tokens == 100
    assert result.change.tokens == 100.0
  end

  test "weekly gives one row per week, oldest first, with empty weeks as zeros", %{project: project} do
    run(project, day(28, 9), "ok")
    run(project, day(14, 9), "error")
    usage(project, day(14, 9), 300)

    rows = Trends.weekly(project, 4, tz: @tz, now: @now)

    assert Enum.map(rows, & &1.key) == ["2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28"]
    assert Enum.map(rows, & &1.runs) == [0, 1, 0, 1]
    assert Enum.map(rows, & &1.errors) == [0, 1, 0, 0]
    assert Enum.map(rows, & &1.tokens) == [0, 300, 0, 0]
  end

  test "a scope only sees its own traces", %{project: project} do
    run(project, day(28, 9), "ok")
    run("someone-else", day(28, 9), "ok")

    assert Trends.compare(project, :week, tz: @tz, now: @now).current.runs == 1
    assert Trends.compare(:all, :week, tz: @tz, now: @now).current.runs == 2
  end

  test "success rate, typical reply time and cache share, with the change in points", %{project: project} do
    # This week: 4 runs, 3 ok; the middle reply takes 2s. 600 of 1000 input tokens came from cache.
    for {at, kind, ms} <- [{day(28, 9), "ok", 1000}, {day(28, 10), "ok", 2000}, {day(29, 9), "ok", 9000}, {day(29, 10), "error", 500}] do
      run(project, at, kind, %{ms: ms})
    end

    Log.append(project, %{"at" => day(28, 10), "agent" => "a", "model" => "m", "in" => 1000, "out" => 0, "cached" => 600})

    # Same point last week: 2 runs, both ok; 200 of 1000 cached.
    run(project, day(21, 9), "ok", %{ms: 4000})
    run(project, day(22, 9), "ok", %{ms: 6000})
    Log.append(project, %{"at" => day(21, 10), "agent" => "a", "model" => "m", "in" => 1000, "out" => 0, "cached" => 200})

    result = Trends.compare(project, :week, tz: @tz, now: @now)

    assert result.current.success == 75.0
    assert result.previous.success == 100.0
    assert result.change.success == -25.0

    # Median of 500, 1000, 2000, 9000 is 1500: the stuck 9s run does not drag it.
    assert result.current.ms == 1500
    assert result.previous.ms == 5000

    assert result.current.cached_share == 60.0
    assert result.change.cached_share == 40.0
  end

  test "a period with no runs has no success rate or reply time rather than a zero", %{project: project} do
    result = Trends.compare(project, :week, tz: @tz, now: @now)

    assert result.current.success == nil
    assert result.current.ms == nil
    assert result.change.success == nil
  end

  test "activity counts runs per hour of day and ranks channels and agents", %{project: project} do
    run(project, day(28, 9), "ok", %{source: "telegram", agent: "support"})
    run(project, day(28, 9), "ok", %{source: "telegram", agent: "support"})
    run(project, day(29, 14), "ok", %{source: "web", agent: "sales"})

    %{hours: hours, sources: sources, agents: agents} = Trends.activity(project, 30, tz: @tz, now: @now)

    assert Enum.count(hours) == 24
    assert Enum.at(hours, 9) == 2
    assert Enum.at(hours, 14) == 1
    assert Enum.sum(hours) == 3
    assert sources == [{"telegram", 2}, {"web", 1}]
    assert agents == [{"support", 2}, {"sales", 1}]
  end
end
