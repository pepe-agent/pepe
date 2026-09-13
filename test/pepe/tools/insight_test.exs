defmodule Pepe.Tools.InsightTest do
  @moduledoc """
  The `insight` tool surface an agent actually reaches, from a conversation - define,
  import_rows, train_now, delete. Querying an already-trained spec (predict/list/describe)
  is `Pepe.Tools.InsightPredict` instead - see `insight_predict_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.Insight, as: InsightTool

  @ctx %{agent: %Agent{name: "clinic"}}

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_insight_tool_#{System.unique_integer([:positive])}")
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
    assert {:error, msg} = InsightTool.run(%{"action" => "define", "name" => "x"}, %{})
    assert msg =~ "no calling agent"
  end

  test "define, import_rows, train_now, delete round-trip" do
    define_args = %{
      "action" => "define",
      "name" => "risk",
      "target_column" => "deteriorating",
      "feature_columns" => ["age", "risk_score"],
      "source_kind" => "import"
    }

    assert {:ok, out} = InsightTool.run(define_args, @ctx)
    assert out =~ "Defined risk"

    rows =
      for i <- 1..30 do
        risk = if rem(i, 2) == 0, do: 1.0, else: 0.0
        %{"age" => 40 + i, "risk_score" => risk, "deteriorating" => if(risk > 0.5, do: "yes", else: "no")}
      end

    assert {:ok, out} = InsightTool.run(%{"action" => "import_rows", "name" => "risk", "rows" => rows}, @ctx)
    assert out =~ "Imported 30"

    assert {:ok, out} = InsightTool.run(%{"action" => "train_now", "name" => "risk"}, @ctx)
    assert out =~ "v1"
    assert out =~ "accuracy"

    assert {:ok, out} = InsightTool.run(%{"action" => "delete", "name" => "risk"}, @ctx)
    assert out =~ "Deleted risk"

    assert {:error, msg} = InsightTool.run(%{"action" => "train_now", "name" => "risk"}, @ctx)
    assert msg =~ "no spec named"
  end

  test "define reports every validation error, joined" do
    assert {:error, msg} = InsightTool.run(%{"action" => "define", "name" => "", "feature_columns" => []}, @ctx)
    assert msg =~ "name"
    assert msg =~ "feature_columns"
  end

  test "unknown action" do
    assert {:error, msg} = InsightTool.run(%{"action" => "levitate"}, @ctx)
    assert msg =~ "unknown or incomplete action"
  end

  test "propose_targets without a connection is an incomplete action" do
    assert {:error, msg} = InsightTool.run(%{"action" => "propose_targets"}, @ctx)
    assert msg =~ "unknown or incomplete action"
  end

  test "propose_targets against an unregistered connection fails clearly, no network needed" do
    assert {:error, msg} = InsightTool.run(%{"action" => "propose_targets", "connection" => "nope"}, @ctx)
    assert msg =~ "nope"
  end

  test "propose_targets against an unregistered connection fails clearly even with an explicit table" do
    # Regression: an explicit `table` skips the information_schema lookup entirely, so the
    # unknown-connection error used to only ever surface inside the per-table scan, which
    # swallows it and reads as "found nothing" instead of the real failure.
    assert {:error, msg} = InsightTool.run(%{"action" => "propose_targets", "connection" => "nope", "table" => "users"}, @ctx)
    assert msg =~ "nope"
  end

  test "predict/list/describe are not this tool's job anymore - insight_predict handles those" do
    assert {:error, msg} = InsightTool.run(%{"action" => "predict", "name" => "risk", "input" => %{}}, @ctx)
    assert msg =~ "unknown or incomplete action"

    assert {:error, msg} = InsightTool.run(%{"action" => "list"}, @ctx)
    assert msg =~ "unknown or incomplete action"

    assert {:error, msg} = InsightTool.run(%{"action" => "describe", "name" => "risk"}, @ctx)
    assert msg =~ "unknown or incomplete action"
  end
end
