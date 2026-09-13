defmodule Pepe.Insight.TrainerTest do
  @moduledoc """
  `Trainer.encode/3`'s pure logic (numeric parsing, label encoding, holdout re-encoding
  with fixed classes) on plain fixture rows - no DB, no Repo needed for either a "db"-
  shaped or an "import"-shaped row set, since `Source.fetch/3` already normalizes both to
  the same `%{"col" => value}` shape before `encode/3` ever sees them.

  The large-data (`:neural`) family selection inside `Trainer.train/2` is not exercised
  here - it only kicks in above `@large_data_threshold` (50k rows), and training on that
  many rows would make this suite slow; that path gets manual verification, the same
  category as `Source.fetch/3`'s "db" branch needing a real Postgres.
  """

  use ExUnit.Case, async: true

  alias Pepe.Insight.Spec
  alias Pepe.Insight.Trainer

  describe "encode/3 - classification" do
    test "label-encodes distinct target values, sorted, and parses numeric features" do
      spec = %Spec{task_type: "classification", target_column: "outcome", feature_columns: ["a", "b"]}

      rows = [
        %{"a" => 1, "b" => 2.0, "outcome" => "yes"},
        %{"a" => "3", "b" => 4, "outcome" => "no"},
        %{"a" => 5, "b" => 6, "outcome" => "yes"}
      ]

      assert {:ok, encoded} = Trainer.encode(rows, spec, nil)
      assert encoded.classes == ["no", "yes"]
      assert Nx.shape(encoded.x) == {3, 2}
      assert Nx.to_flat_list(encoded.y) == [1, 0, 1]
    end

    test "reuses given classes for a holdout split, mapping an unseen label to index -1" do
      spec = %Spec{task_type: "classification", target_column: "outcome", feature_columns: ["a"]}
      assert {:ok, encoded} = Trainer.encode([%{"a" => 1, "outcome" => "surprise"}], spec, ["no", "yes"])
      assert Nx.to_flat_list(encoded.y) == [-1]
      assert encoded.classes == ["no", "yes"]
    end

    test "fails clearly with fewer than 2 distinct classes" do
      spec = %Spec{task_type: "classification", target_column: "outcome", feature_columns: ["a"]}
      rows = [%{"a" => 1, "outcome" => "only"}, %{"a" => 2, "outcome" => "only"}]
      assert {:error, msg} = Trainer.encode(rows, spec, nil)
      assert msg =~ "at least 2 distinct classes"
    end

    test "fails clearly on a non-numeric feature value" do
      spec = %Spec{task_type: "classification", target_column: "outcome", feature_columns: ["a"]}
      rows = [%{"a" => "not-a-number", "outcome" => "x"}, %{"a" => 1, "outcome" => "y"}]
      assert {:error, msg} = Trainer.encode(rows, spec, nil)
      assert msg =~ "feature column"
    end
  end

  describe "encode/3 - regression" do
    test "parses numeric targets, including Decimal" do
      spec = %Spec{task_type: "regression", target_column: "amount", feature_columns: ["a"]}
      rows = [%{"a" => 1, "amount" => Decimal.new("2.5")}, %{"a" => 2, "amount" => 3}]

      assert {:ok, encoded} = Trainer.encode(rows, spec, nil)
      assert Nx.to_flat_list(encoded.y) == [2.5, 3.0]
      assert encoded.classes == nil
    end

    test "fails clearly on a non-numeric target value" do
      spec = %Spec{task_type: "regression", target_column: "amount", feature_columns: ["a"]}
      assert {:error, msg} = Trainer.encode([%{"a" => 1, "amount" => "n/a"}], spec, nil)
      assert msg =~ "target column"
    end
  end
end
