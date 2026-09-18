defmodule Pepe.Insight.Categorical do
  @moduledoc """
  Value-based one-hot encoding for feature columns that aren't numeric - shared by `Trainer`
  (fitting) and `Predictor` (inference), same convention as `Pepe.Insight.Numeric`: value-based
  rather than schema-based, since an imported row has no `information_schema` to consult, and a
  `"db"` row and an `"import"` row must be classified by exactly the same rule.

  A column is categorical if *any* of its values fails `Numeric.to_number/1` - the whole column
  is then treated as categorical (every value stringified via `to_label/1`), never partially
  numeric/partially categorical, which would make a one-hot block incoherent.

  Scoped to classification/regression/forecast feature columns only - `Trainer.fit_clustering/2`
  keeps requiring all-numeric features (k-means/silhouette distance and `cluster_summaries/2`'s
  per-feature means don't generalize to a category the same way a fixed target's supervised
  signal does), so this module is never called from that path.
  """

  alias Pepe.Insight.Numeric

  @max_categories 20

  @doc """
  Resolve which of `feature_columns` are categorical (not all-numeric) in `rows`, and each
  one's vocabulary (sorted distinct labels). Called once, on the full cleaned row set, before
  any split - the same timing `Trainer.resolve_classes/2` already uses for the classification
  target, and for the same reason: a rare category landing entirely in one CV fold by chance
  must not change what the vocabulary is.
  """
  @spec resolve([map()], [String.t()]) :: {:ok, %{String.t() => [String.t()]}} | {:error, String.t()}
  def resolve(rows, feature_columns) do
    Enum.reduce_while(feature_columns, {:ok, %{}}, fn col, {:ok, acc} ->
      case resolve_column(rows, col) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, vocab} -> {:cont, {:ok, Map.put(acc, col, vocab)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_column(rows, col) do
    values = Enum.map(rows, &Map.get(&1, col))

    if Enum.all?(values, &numeric?/1) do
      {:ok, nil}
    else
      vocab = values |> Enum.map(&to_label/1) |> Enum.uniq() |> Enum.sort()

      if length(vocab) > @max_categories do
        {:error, "feature column #{inspect(col)} has #{length(vocab)} distinct values, too many to one-hot encode (max #{@max_categories})"}
      else
        {:ok, vocab}
      end
    end
  end

  defp numeric?(value), do: match?({:ok, _}, Numeric.to_number(value))

  @doc """
  Build the numeric feature vector for one row (training) or one predict input, in
  `feature_columns` order. A plain column contributes one number; a column present in
  `categories` contributes a one-hot block (length = its vocabulary size). A value not in the
  vocabulary (an unseen category at predict time) encodes to all-zeros for that block rather
  than a reserved "unknown" column - a column never has a training example in an "unknown" slot
  anyway, so reserving one would buy width, not signal.
  """
  @spec feature_vector(map(), [String.t()], %{String.t() => [String.t()]}) :: {:ok, [float()]} | {:error, String.t()}
  def feature_vector(row, feature_columns, categories) when is_map(row) do
    feature_columns
    |> Enum.reduce_while({:ok, []}, fn col, {:ok, acc} ->
      case column_values(row, col, categories) do
        {:ok, values} -> {:cont, {:ok, [values | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp column_values(row, col, categories) do
    case Map.get(categories, col) do
      nil ->
        case Numeric.to_number(Map.get(row, col)) do
          {:ok, n} -> {:ok, [n]}
          :error -> {:error, "feature column #{inspect(col)} has a missing or non-numeric value"}
        end

      vocab ->
        label = to_label(Map.get(row, col))
        {:ok, Enum.map(vocab, &if(&1 == label, do: 1.0, else: 0.0))}
    end
  end

  @doc "Stringify a raw value into a category label - shared with `Trainer`'s classification target encoding."
  @spec to_label(term()) :: String.t()
  def to_label(nil), do: ""
  def to_label(v) when is_binary(v), do: v
  def to_label(%Decimal{} = d), do: Decimal.to_string(d)
  def to_label(v), do: to_string(v)
end
