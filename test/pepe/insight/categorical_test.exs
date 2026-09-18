defmodule Pepe.Insight.CategoricalTest do
  @moduledoc """
  `Categorical.resolve/2` (which columns are categorical, and their vocabulary) and
  `Categorical.feature_vector/3` (the actual one-hot encoding) on plain fixture rows -
  no DB, no Repo needed, same style as `Pepe.Insight.Numeric`'s implicit coverage via
  `TrainerTest`.
  """

  use ExUnit.Case, async: true

  alias Pepe.Insight.Categorical

  describe "resolve/2" do
    test "leaves an all-numeric column out of the result" do
      rows = [%{"a" => 1}, %{"a" => "2"}, %{"a" => 3.5}]
      assert {:ok, %{}} = Categorical.resolve(rows, ["a"])
    end

    test "treats a column with any non-numeric value as categorical, sorted distinct vocabulary" do
      rows = [%{"a" => "red"}, %{"a" => "blue"}, %{"a" => "red"}]
      assert {:ok, %{"a" => ["blue", "red"]}} = Categorical.resolve(rows, ["a"])
    end

    test "resolves several columns independently" do
      rows = [%{"a" => "x", "b" => 1}, %{"a" => "y", "b" => 2}]
      assert {:ok, %{"a" => ["x", "y"]}} = Categorical.resolve(rows, ["a", "b"])
    end

    test "fails clearly past the cardinality cap" do
      rows = for i <- 1..21, do: %{"a" => "v#{i}"}
      assert {:error, msg} = Categorical.resolve(rows, ["a"])
      assert msg =~ "too many"
      assert msg =~ "21"
    end
  end

  describe "feature_vector/3" do
    test "passes a plain numeric column through unchanged when categories is empty" do
      assert {:ok, [1.0, 2.0]} = Categorical.feature_vector(%{"a" => 1, "b" => "2"}, ["a", "b"], %{})
    end

    test "one-hot encodes a categorical column in vocabulary order" do
      categories = %{"color" => ["blue", "red"]}
      assert {:ok, red} = Categorical.feature_vector(%{"n" => 10, "color" => "red"}, ["n", "color"], categories)
      assert red == [10.0, 0.0, 1.0]
      assert {:ok, blue} = Categorical.feature_vector(%{"n" => 10, "color" => "blue"}, ["n", "color"], categories)
      assert blue == [10.0, 1.0, 0.0]
    end

    test "an unseen category encodes to all-zeros instead of erroring" do
      categories = %{"color" => ["blue", "red"]}
      assert {:ok, vector} = Categorical.feature_vector(%{"color" => "green"}, ["color"], categories)
      assert vector == [0.0, 0.0]
    end

    test "fails clearly on a missing/non-numeric value for a plain numeric column" do
      assert {:error, msg} = Categorical.feature_vector(%{"a" => "not-a-number"}, ["a"], %{})
      assert msg =~ "feature column"
    end
  end
end
