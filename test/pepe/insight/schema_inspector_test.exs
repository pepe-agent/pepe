defmodule Pepe.Insight.SchemaInspectorTest do
  @moduledoc """
  `SchemaInspector.score_rows/3`'s pure heuristic - fixture columns/rows, no DB needed
  (same split `Pepe.Insight.Trainer.encode/3` keeps from `Source.fetch/3`, for the same
  reason). The DB-querying half (`propose/3`'s table discovery + sampling) needs a real
  Postgres and is exercised by manual verification instead, same gap
  `test/pepe/tools/db_query_test.exs` already documents.
  """

  use ExUnit.Case, async: true

  alias Pepe.Insight.SchemaInspector

  test "excludes id-looking columns entirely, even when they'd otherwise score well" do
    columns = ["id", "user_id", "status"]

    rows =
      for i <- 1..20 do
        [i, rem(i, 5), if(rem(i, 2) == 0, do: "active", else: "inactive")]
      end

    candidates = SchemaInspector.score_rows("users", columns, rows)
    refute Enum.any?(candidates, &(&1.column in ["id", "user_id"]))
    assert Enum.any?(candidates, &(&1.column == "status"))
  end

  test "a low-cardinality string column is a classification candidate" do
    columns = ["status"]
    rows = for i <- 1..30, do: [if(rem(i, 3) == 0, do: "cancelled", else: "active")]

    assert [candidate] = SchemaInspector.score_rows("orders", columns, rows)
    assert candidate.task_type == "classification"
    assert candidate.reason =~ "distinct values"
  end

  test "a numeric column with real spread is a regression candidate" do
    columns = ["total_amount"]
    rows = for i <- 1..30, do: [i * 3.7]

    assert [candidate] = SchemaInspector.score_rows("orders", columns, rows)
    assert candidate.task_type == "regression"
    assert candidate.reason =~ "spread"
  end

  test "a numeric column with low cardinality (a rating) is a classification candidate, not regression" do
    columns = ["rating"]
    rows = for i <- 1..30, do: [rem(i, 5) + 1]

    assert [candidate] = SchemaInspector.score_rows("reviews", columns, rows)
    assert candidate.task_type == "classification"
  end

  test "a low-cardinality numeric column counts by numeric value, not raw representation" do
    # Regression: Decimal.new("3.0") and Decimal.new("3.00") represent the same number but
    # aren't `==`, and would inflate the distinct count if the raw (pre-Numeric.to_number)
    # values were compared instead of the parsed numbers.
    columns = ["rating"]

    rows =
      for i <- 1..30 do
        cond do
          rem(i, 3) == 0 -> [Decimal.new("3.0")]
          rem(i, 3) == 1 -> [Decimal.new("3.00")]
          true -> [Decimal.new("4")]
        end
      end

    assert [candidate] = SchemaInspector.score_rows("reviews", columns, rows)
    assert candidate.task_type == "classification"
    assert candidate.reason =~ "2 distinct values"
  end

  test "an all-unique column (every row distinct) is not a candidate" do
    columns = ["email"]
    rows = for i <- 1..30, do: ["user#{i}@example.com"]

    assert SchemaInspector.score_rows("users", columns, rows) == []
  end

  test "a constant column (one distinct value) is not a candidate" do
    columns = ["region"]
    rows = for _ <- 1..30, do: ["us-east"]

    assert SchemaInspector.score_rows("orders", columns, rows) == []
  end

  test "a column with too few non-nil sampled values is not a candidate" do
    columns = ["notes"]
    rows = for i <- 1..30, do: [if(i <= 3, do: "a", else: nil)]

    assert SchemaInspector.score_rows("orders", columns, rows) == []
  end

  test "a keyword-matching column name scores higher than an equivalent non-matching one" do
    rows = for i <- 1..30, do: if(rem(i, 3) == 0, do: "yes", else: "no")

    [risk] = SchemaInspector.score_rows("t", ["risk_flag"], Enum.map(rows, &[&1]))
    [plain] = SchemaInspector.score_rows("t", ["column_a"], Enum.map(rows, &[&1]))

    assert risk.score > plain.score
    assert risk.reason =~ "outcome/label"
    refute plain.reason =~ "outcome/label"
  end

  test "candidates are independent per column - multiple columns can each score" do
    columns = ["status", "amount", "id"]
    rows = for i <- 1..30, do: [if(rem(i, 2) == 0, do: "paid", else: "pending"), i * 1.5, i]

    candidates = SchemaInspector.score_rows("orders", columns, rows)
    assert length(candidates) == 2
    assert Enum.any?(candidates, &(&1.column == "status" and &1.task_type == "classification"))
    assert Enum.any?(candidates, &(&1.column == "amount" and &1.task_type == "regression"))
  end
end
