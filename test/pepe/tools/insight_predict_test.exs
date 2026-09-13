defmodule Pepe.Tools.InsightPredictTest do
  @moduledoc """
  `insight_predict`'s read-only surface - predict/list/describe against a spec already
  defined and trained via the `insight` tool (see `insight_test.exs`). Also proves this
  tool has no define/import_rows/train_now/delete power of its own.
  """

  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.Insight, as: InsightTool
  alias Pepe.Tools.InsightPredict

  @ctx %{agent: %Agent{name: "clinic"}}

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_insight_predict_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "clinic", system_prompt: "x", tools: []})
    :ok
  end

  test "refuses without a calling agent in context" do
    assert {:error, msg} = InsightPredict.run(%{"action" => "list"}, %{})
    assert msg =~ "no calling agent"
  end

  test "list is empty with no specs defined" do
    assert {:ok, out} = InsightPredict.run(%{"action" => "list"}, @ctx)
    assert out =~ "No insight specs"
  end

  test "unknown action" do
    assert {:error, msg} = InsightPredict.run(%{"action" => "levitate"}, @ctx)
    assert msg =~ "unknown or incomplete action"
  end

  test "has no define/import_rows/train_now/delete power of its own" do
    for action <- ~w(define import_rows train_now delete) do
      assert {:error, msg} = InsightPredict.run(%{"action" => action, "name" => "risk"}, @ctx)
      assert msg =~ "unknown or incomplete action"
    end
  end

  test "predict, describe round-trip against a spec defined and trained via insight" do
    define_args = %{
      "action" => "define",
      "name" => "risk",
      "target_column" => "deteriorating",
      "feature_columns" => ["age", "risk_score"],
      "source_kind" => "import"
    }

    assert {:ok, _} = InsightTool.run(define_args, @ctx)

    rows =
      for i <- 1..30 do
        risk = if rem(i, 2) == 0, do: 1.0, else: 0.0
        %{"age" => 40 + i, "risk_score" => risk, "deteriorating" => if(risk > 0.5, do: "yes", else: "no")}
      end

    assert {:ok, _} = InsightTool.run(%{"action" => "import_rows", "name" => "risk", "rows" => rows}, @ctx)

    assert {:error, msg} = InsightPredict.run(%{"action" => "predict", "name" => "risk", "input" => %{"age" => 50}}, @ctx)
    assert msg =~ "train_now"

    assert {:ok, _} = InsightTool.run(%{"action" => "train_now", "name" => "risk"}, @ctx)

    assert {:ok, out} = InsightPredict.run(%{"action" => "predict", "name" => "risk", "input" => %{"age" => 50, "risk_score" => 1.0}}, @ctx)
    assert out =~ "risk predicts"

    assert {:ok, out} = InsightPredict.run(%{"action" => "describe", "name" => "risk"}, @ctx)
    assert out =~ "classification on deteriorating"
    assert out =~ "v1 (logistic_regression)"

    assert {:ok, _} = InsightTool.run(%{"action" => "delete", "name" => "risk"}, @ctx)
    assert {:error, msg} = InsightPredict.run(%{"action" => "describe", "name" => "risk"}, @ctx)
    assert msg =~ "no spec named"
  end

  test "clustering: predict a group + anomaly, describe lists group summaries" do
    define_args = %{
      "action" => "define",
      "name" => "segments",
      "feature_columns" => ["age", "spend"],
      "task_type" => "clustering",
      "source_kind" => "import"
    }

    assert {:ok, _} = InsightTool.run(define_args, @ctx)

    rows =
      for(i <- 1..15, do: %{"age" => 20 + :rand.uniform(3), "spend" => 10 + :rand.uniform(3), "id" => i}) ++
        for i <- 1..15, do: %{"age" => 60 + :rand.uniform(3), "spend" => 90 + :rand.uniform(3), "id" => i}

    assert {:ok, _} = InsightTool.run(%{"action" => "import_rows", "name" => "segments", "rows" => rows}, @ctx)
    assert {:ok, out} = InsightTool.run(%{"action" => "train_now", "name" => "segments"}, @ctx)
    assert out =~ "kmeans"

    assert {:ok, out} =
             InsightPredict.run(%{"action" => "predict", "name" => "segments", "input" => %{"age" => 5000, "spend" => 5000}}, @ctx)

    assert out =~ "ANOMALOUS"

    assert {:ok, out} = InsightPredict.run(%{"action" => "describe", "name" => "segments"}, @ctx)
    assert out =~ "group 0:"
  end

  test "forecast: predicts a future date" do
    define_args = %{
      "action" => "define",
      "name" => "sales_forecast",
      "target_column" => "sales",
      "time_column" => "day",
      "task_type" => "forecast",
      "source_kind" => "import"
    }

    assert {:ok, _} = InsightTool.run(define_args, @ctx)

    rows = for i <- 0..29, do: %{"day" => Date.add(~D[2026-01-01], i) |> Date.to_iso8601(), "sales" => 100 + i * 2}

    assert {:ok, _} = InsightTool.run(%{"action" => "import_rows", "name" => "sales_forecast", "rows" => rows}, @ctx)
    assert {:ok, _} = InsightTool.run(%{"action" => "train_now", "name" => "sales_forecast"}, @ctx)

    assert {:ok, out} =
             InsightPredict.run(%{"action" => "predict", "name" => "sales_forecast", "input" => %{"day" => "2026-02-10"}}, @ctx)

    assert out =~ "sales_forecast predicts"
  end
end
