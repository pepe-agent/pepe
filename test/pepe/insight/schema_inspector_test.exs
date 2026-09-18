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
    assert match?([_, _], candidates)
    assert Enum.any?(candidates, &(&1.column == "status" and &1.task_type == "classification"))
    assert Enum.any?(candidates, &(&1.column == "amount" and &1.task_type == "regression"))
  end

  describe "forecast candidates" do
    test "pairs a real date/timestamp column with the best regression target" do
      columns = ["created_at", "amount"]

      rows =
        for i <- 1..30 do
          [DateTime.add(~U[2026-01-01 00:00:00Z], i, :day), i * 3.7]
        end

      candidates = SchemaInspector.score_rows("orders", columns, rows)
      assert forecast = Enum.find(candidates, &(&1.task_type == "forecast"))
      assert forecast.column == "amount"
      assert forecast.time_column == "created_at"
      assert forecast.reason =~ "created_at"
    end

    test "a date-shaped string column also counts as a time column" do
      columns = ["day", "revenue"]
      rows = for i <- 1..30, do: [Date.to_iso8601(Date.add(~D[2026-01-01], i)), i * 2.1]

      candidates = SchemaInspector.score_rows("orders", columns, rows)
      assert Enum.any?(candidates, &(&1.task_type == "forecast" and &1.time_column == "day"))
    end

    test "a bare integer column is never treated as a time column (would false-positive as a 1970s Unix timestamp)" do
      columns = ["rating", "amount"]
      rows = for i <- 1..30, do: [rem(i, 5) + 1, i * 2.1]

      candidates = SchemaInspector.score_rows("orders", columns, rows)
      refute Enum.any?(candidates, &(&1.task_type == "forecast"))
    end

    test "no forecast candidate without a regression-shaped numeric column to predict" do
      columns = ["created_at", "status"]

      rows =
        for i <- 1..30 do
          status = if rem(i, 2) == 0, do: "paid", else: "pending"
          [DateTime.add(~U[2026-01-01 00:00:00Z], i, :day), status]
        end

      candidates = SchemaInspector.score_rows("orders", columns, rows)
      refute Enum.any?(candidates, &(&1.task_type == "forecast"))
    end
  end

  describe "clustering candidates" do
    test "bundles numeric columns with real variation as a feature-column set" do
      columns = ["age", "spend", "visits"]
      rows = for i <- 1..30, do: [20 + rem(i, 40), i * 12.5, rem(i, 10)]

      candidates = SchemaInspector.score_rows("customers", columns, rows)
      assert cluster = Enum.find(candidates, &(&1.task_type == "clustering"))
      assert cluster.feature_columns == ["age", "spend", "visits"]
      assert cluster.table == "customers"
    end

    test "no clustering candidate with fewer than 2 qualifying numeric columns" do
      columns = ["spend", "status"]
      rows = for i <- 1..30, do: [i * 12.5, if(rem(i, 2) == 0, do: "paid", else: "pending")]

      candidates = SchemaInspector.score_rows("customers", columns, rows)
      refute Enum.any?(candidates, &(&1.task_type == "clustering"))
    end

    test "caps the feature-column bundle at 5 columns" do
      columns = for i <- 1..8, do: "num#{i}"
      rows = for i <- 1..30, do: Enum.map(1..8, fn n -> i * n * 1.1 end)

      candidates = SchemaInspector.score_rows("wide", columns, rows)
      assert cluster = Enum.find(candidates, &(&1.task_type == "clustering"))
      assert [_, _, _, _, _] = cluster.feature_columns
    end
  end
end
