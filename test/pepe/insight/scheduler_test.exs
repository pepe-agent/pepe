defmodule Pepe.Insight.SchedulerTest do
  @moduledoc """
  `Pepe.Insight.Scheduler`'s two gates - `due_specs/1` (has `retrain_interval_s` elapsed?)
  and the row-count check (have `min_new_rows` new rows actually arrived?) - both have to
  pass before a tick actually retrains anything.
  """

  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Insight
  alias Pepe.Insight.Scheduler

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_insight_sched_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    start_supervised!({Task.Supervisor, name: Pepe.Insight.TaskSupervisor})
    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "clinic", system_prompt: "x", tools: []})
    :ok
  end

  defp tick, do: send(Scheduler, :tick)

  # 100 tries (2s) was tight enough to flake on a loaded CI runner - the first fit in a
  # test run pays Scholar/Nx's numerical-code compilation overhead, not just the actual
  # 20-row logistic regression, which can occasionally run past 2s on a busy shared
  # runner even though it's near-instant on a warm/idle machine.
  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp rows(n) do
    for i <- 1..n do
      risk = if rem(i, 2) == 0, do: 1.0, else: 0.0
      %{"age" => 40 + i, "risk_score" => risk, "y" => if(risk > 0.5, do: "yes", else: "no")}
    end
  end

  defp define(name, opts) do
    attrs = %{
      "agent" => "clinic",
      "name" => name,
      "target_column" => "y",
      "feature_columns" => ["age", "risk_score"],
      "source" => %{"kind" => "import"},
      "retrain_interval_s" => Keyword.get(opts, :retrain_interval_s),
      "min_new_rows" => Keyword.get(opts, :min_new_rows, 5)
    }

    {:ok, _} = Insight.define_spec(attrs)
  end

  test "a due spec with enough new rows retrains on tick" do
    define("risk", retrain_interval_s: 0, min_new_rows: 5)
    {:ok, _} = Insight.import_rows("clinic", "risk", rows(20))

    tick()
    wait_until(fn -> match?(%{"status" => "ready"}, Insight.get_spec("clinic", "risk")) end)

    spec = Insight.get_spec("clinic", "risk")
    assert spec["last_trained_at"] != nil
    assert spec["row_count_at_last_train"] == 20
  end

  test "a due spec without enough new rows is left alone" do
    define("risk", retrain_interval_s: 0, min_new_rows: 1000)
    {:ok, _} = Insight.import_rows("clinic", "risk", rows(20))

    tick()
    # Neither gate spawns a task when it stops a spec, so handle_info(:tick, ...) has fully
    # returned by the time this synchronous call to the same process replies.
    :sys.get_state(Scheduler)
    spec = Insight.get_spec("clinic", "risk")
    assert spec["status"] == "pending"
    assert spec["last_trained_at"] == nil
  end

  test "a spec with no retrain_interval_s is never picked up" do
    define("risk", retrain_interval_s: nil)
    {:ok, _} = Insight.import_rows("clinic", "risk", rows(20))

    tick()
    :sys.get_state(Scheduler)
    spec = Insight.get_spec("clinic", "risk")
    assert spec["status"] == "pending"
  end

  test "a spec whose agent no longer exists is skipped, not crashed" do
    define("risk", retrain_interval_s: 0, min_new_rows: 5)
    {:ok, _} = Insight.import_rows("clinic", "risk", rows(20))
    # canonical_agent/1 stores the resolved handle (e.g. "default/clinic"), not the bare
    # ref - capture it before deleting, since Config.get_agent("clinic") won't resolve
    # anything afterward for either the agent or the spec's own agent-scoped lookups.
    stored_agent = Insight.get_spec("clinic", "risk")["agent"]
    Config.delete_agent("clinic")

    tick()
    :sys.get_state(Scheduler)

    assert Process.alive?(Process.whereis(Scheduler))
    # The spec is due, with plenty of new rows, so it would have trained to "ready" had the
    # orphaned-agent guard not stopped it - reading it back straight from the schema is the
    # only way left to confirm that, since it's no longer reachable via the agent-scoped API.
    stored = Pepe.Repo.get_by(Pepe.Insight.Spec, agent: stored_agent, name: "risk")
    assert stored.status == "pending"
  end
end
