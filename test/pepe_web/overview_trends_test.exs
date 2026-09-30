defmodule PepeWeb.OverviewTrendsTest do
  @moduledoc """
  The overview's trend section: the week/month comparison tiles and the charts. What matters
  here is what the server hands the chart hook (the spec the browser draws), not the pixels.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Trace.Trace
  alias Pepe.Usage.Log

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_overview_trends_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open_tab(view, tab), do: view |> element("button[role=tab][phx-value-tab=#{tab}]") |> render_click()

  defp spec(html, id) do
    {:ok, doc} = Floki.parse_document(html)
    [raw] = doc |> Floki.find("##{id}") |> Floki.attribute("data-spec")
    Jason.decode!(raw)
  end

  test "shows the comparison tiles and three charts, each fed an aligned series" do
    now = System.system_time(:second)
    project = Config.default_project_slug()
    Log.append(project, %{"at" => now - 60, "agent" => "a", "model" => "m", "in" => 4000, "out" => 100})

    Repo.insert_all(Trace, [
      %{id: "t-ok", scope: project, at: now - 60, agent: "a", outcome: %{"kind" => "ok"}, events: []},
      %{id: "t-bad", scope: project, at: now - 50, agent: "a", outcome: %{"kind" => "error"}, events: []}
    ])

    {:ok, view, _html} = live(conn(), "/")

    charts = %{
      "trends" => ["chart-spend", "chart-runs"],
      "health" => ["chart-success", "chart-cache", "chart-hours", "chart-sources", "chart-latency", "chart-agents"],
      "usage" => ["chart-activity"]
    }

    for {tab, ids} <- charts, id <- ids do
      html = open_tab(view, tab)
      assert %{"labels" => labels, "series" => series} = spec(html, id)
      assert Enum.all?(series, &(Enum.count(&1["values"]) == Enum.count(labels)))
    end

    html = open_tab(view, "trends")
    weekly = spec(html, "chart-runs")
    assert Enum.count(weekly["labels"]) == 8
    assert List.last(weekly["labels"]) == "This week"
    assert [%{"name" => "Runs"}, %{"name" => "Errors"}] = weekly["series"]
    assert weekly["series"] |> Enum.map(&List.last(&1["values"])) == [2, 1]
  end

  test "the health charts: success rate in percent, a weekless gap is null, hours cover the whole day" do
    now = System.system_time(:second)
    project = Config.default_project_slug()

    Repo.insert_all(Trace, [
      %{id: "h-ok", scope: project, at: now - 60, agent: "a", source: "telegram", ms: 1200, outcome: %{"kind" => "ok"}, events: []},
      %{id: "h-bad", scope: project, at: now - 50, agent: "a", source: "web", ms: 800, outcome: %{"kind" => "error"}, events: []}
    ])

    {:ok, view, _html} = live(conn(), "/")
    html = open_tab(view, "health")

    success = spec(html, "chart-success")
    assert success["unit"] == "percent"
    assert success["goal"] == %{"value" => 95, "label" => "95%"}
    # Seven weeks with no runs are gaps (null), not zeros: nothing happened, it did not all fail.
    assert success["series"] |> hd() |> Map.fetch!("values") |> Enum.take(7) |> Enum.all?(&is_nil/1)
    assert success["series"] |> hd() |> Map.fetch!("values") |> List.last() == 50.0

    hours = spec(html, "chart-hours")
    assert Enum.count(hours["labels"]) == 24
    assert hours["series"] |> hd() |> Map.fetch!("values") |> Enum.sum() == 2

    sources = spec(html, "chart-sources")
    assert Enum.sort(sources["labels"]) == ["telegram", "web"]
  end

  test "the month toggle switches what the tiles compare against" do
    project = Config.default_project_slug()
    tz = Config.default_timezone()
    today = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    # The very first instant of the previous week and of the previous month: always inside the
    # "same point of the previous period" window, whatever day or hour the suite runs at.
    prev_week = today |> Date.beginning_of_week() |> Date.add(-7)
    prev_month = today |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()

    for date <- [prev_week, prev_month] do
      at = date |> DateTime.new!(~T[00:00:00], tz) |> DateTime.to_unix()
      Log.append(project, %{"at" => at, "agent" => "a", "model" => "m", "in" => 100, "out" => 0})
    end

    {:ok, view, _html} = live(conn(), "/")
    html = open_tab(view, "trends")
    assert html =~ "vs last week"
    assert has_element?(view, "button[phx-value-period=week][aria-pressed=true]")

    html = view |> element("button[phx-value-period=month]") |> render_click()

    assert html =~ "vs last month"
    refute html =~ "vs last week"
    assert has_element?(view, "button[phx-value-period=month][aria-pressed=true]")
  end

  test "the overview opens on the summary and only draws the charts of the tab you open" do
    {:ok, view, html} = live(conn(), "/")

    assert html =~ "Live sessions"
    refute html =~ ~s(phx-hook="Chart")
    # The week/month switch keeps its space (so the tab bar never changes height) but is hidden.
    assert has_element?(view, "div.invisible[role=group] button[phx-value-period=week]")

    html = open_tab(view, "trends")
    assert html =~ ~s(id="chart-spend")
    refute html =~ "Live sessions"
    refute has_element?(view, "div.invisible[role=group]")

    # A tab can also be asked for in the address, so a link lands on it.
    {:ok, _view, html} = live(conn(), "/overview?tab=health")
    assert html =~ ~s(id="chart-success")
  end
end
