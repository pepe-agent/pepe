defmodule Pepe.Insight.SchemaInspector do
  @moduledoc """
  Heuristic target-column candidates for `insight`'s `propose_targets` action - read-only,
  never trains or persists anything. Inspects a `"db"` connection's tables (via the exact
  same tenant-scoped `Pepe.DB.Query.run/3` path `db_query` and `Pepe.Insight.Source` both
  use, so RLS applies here too) plus a small sample of rows, and scores candidates by
  cheap, explainable signals: a low-cardinality column (2-20 distinct values in the
  sample, not every row unique) is a classification candidate; a numeric column with real
  spread is a regression candidate; either gets a small boost if its name suggests an
  outcome (`status`, `risk`, `churn`, ...). A column that looks like an id (name ending in
  `id`/`uuid`/`guid`) is never a candidate.

  `information_schema.tables` itself is not RLS-filtered, so on a connection shared across
  tenants every tenant sees the same table names (not the data in them) - the same
  visibility `db_query` already allows for any query naming a table directly, not a new
  leak introduced here.

  A heuristic, not a guarantee - same caveat the tool description gives the model: confirm
  a suggestion with a human before calling `define` on it, never define off this alone.
  """

  alias Pepe.DB.Query
  alias Pepe.Insight.Numeric

  @max_tables 10
  @sample_rows 200
  @min_sample 5
  @max_distinct 20
  @identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/
  @id_pattern ~r/(^|_)(id|uuid|guid)\z/i
  @keywords ~w(status outcome result risk score category type label flag churn convert deteriorat cancel)

  @doc """
  Top 5 heuristic target-column candidates, across `table` (or up to #{@max_tables}
  auto-discovered tables, if `table` is `nil`) in `connection`. `ctx` is the same tenant
  context `Pepe.DB.Query.run/3` takes everywhere else.
  """
  @spec propose(String.t(), String.t() | nil, map()) :: {:ok, [map()]} | {:error, term()}
  def propose(connection, table, ctx) do
    with {:ok, tables} <- tables_to_scan(connection, table, ctx),
         {:ok, candidates} <- score_tables(connection, tables, ctx) do
      {:ok, candidates |> Enum.sort_by(& &1.score, :desc) |> Enum.take(5)}
    end
  end

  defp tables_to_scan(_connection, table, _ctx) when is_binary(table) and table != "" do
    if Regex.match?(@identifier, table), do: {:ok, [table]}, else: {:error, "table must be a valid identifier"}
  end

  defp tables_to_scan(connection, _table, ctx) do
    sql = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name LIMIT #{@max_tables}"

    case Query.run(connection, sql, ctx) do
      {:ok, %{rows: rows}} ->
        # Discovered from the database's own catalog, not user input - still re-validated
        # before ever being interpolated into a query, since a catalog can hold names a
        # plain identifier would reject (quoted, mixed-case, containing spaces or a
        # reserved word): skip those rather than risk a malformed or unsafe query.
        {:ok, rows |> Enum.map(fn [name] -> name end) |> Enum.filter(&Regex.match?(@identifier, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp score_tables(connection, tables, ctx) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, acc} ->
      case score_table(connection, table, ctx) do
        {:ok, candidates} -> {:cont, {:ok, acc ++ candidates}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A per-table SQL failure (that one table went away, no SELECT grant on it specifically)
  # contributes zero candidates for that table rather than failing the whole multi-table
  # scan. A structural failure (bad connection, misconfigured tenant binding, a
  # write-looking query rejected) would fail identically for every remaining table too, so
  # it propagates instead of being silently swallowed and misread as "found nothing."
  defp score_table(connection, table, ctx) do
    case Query.run(connection, "SELECT * FROM #{table} LIMIT #{@sample_rows}", ctx) do
      {:ok, %{columns: columns, rows: rows}} when is_list(columns) -> {:ok, score_rows(table, columns, rows)}
      {:ok, %{columns: nil}} -> {:ok, []}
      {:error, %Postgrex.Error{}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Pure - takes already-fetched columns/rows, no DB involved, so the scoring heuristic
  # itself is unit-testable with fixture data (same split Pepe.Insight.Trainer's encode/3
  # keeps from Source.fetch/3, and for the same reason).
  @spec score_rows(String.t(), [String.t()], [[term()]]) :: [map()]
  def score_rows(table, columns, rows) do
    maps = Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
    columns |> Enum.reject(&id_like?/1) |> Enum.flat_map(&score_column(table, &1, maps))
  end

  defp id_like?(name), do: Regex.match?(@id_pattern, name)

  defp score_column(table, column, rows) do
    values = rows |> Enum.map(&Map.get(&1, column)) |> Enum.reject(&is_nil/1)
    total = length(values)

    if total < @min_sample do
      []
    else
      if numeric_column?(values),
        do: numeric_candidate(table, column, values, total),
        else: categorical_candidate(table, column, values, total)
    end
  end

  defp numeric_column?(values), do: Enum.all?(values, &match?({:ok, _}, Numeric.to_number(&1)))

  defp numeric_candidate(table, column, values, total) do
    numbers =
      Enum.map(values, fn v ->
        {:ok, n} = Numeric.to_number(v)
        n
      end)

    distinct = numbers |> Enum.uniq() |> length()

    cond do
      # A numeric column with only a handful of distinct values (a 1-5 rating, a status
      # code) reads better as something to classify than something to regress on. Passing
      # `numbers` (not the raw `values`) keeps this consistent with the `distinct` count
      # just computed above - two Decimals of different scale representing the same
      # number (3.0 vs 3.00) would otherwise count as 2 distinct raw values here, but
      # already collapsed to 1 in `numbers`.
      distinct >= 2 and distinct <= @max_distinct -> categorical_candidate(table, column, numbers, total)
      distinct > @max_distinct -> regression_candidate(table, column, numbers, total)
      true -> []
    end
  end

  defp regression_candidate(table, column, numbers, total) do
    mean = Enum.sum(numbers) / total
    variance = Enum.reduce(numbers, 0.0, fn n, acc -> acc + :math.pow(n - mean, 2) end) / total
    stddev = :math.sqrt(variance)

    if stddev > 0 do
      [
        %{
          table: table,
          column: column,
          task_type: "regression",
          score: Float.round(min(stddev / (abs(mean) + 1.0), 5.0) + keyword_bonus(column), 4),
          reason:
            "numeric with real spread (mean=#{Float.round(mean, 2)}, stddev=#{Float.round(stddev, 2)}) across #{total} sampled rows" <>
              keyword_note(column)
        }
      ]
    else
      []
    end
  end

  defp categorical_candidate(table, column, values, total) do
    distinct = values |> Enum.uniq() |> length()

    if distinct >= 2 and distinct <= @max_distinct and distinct < total do
      [
        %{
          table: table,
          column: column,
          task_type: "classification",
          score: Float.round(10.0 / distinct + keyword_bonus(column), 4),
          reason: "#{distinct} distinct values across #{total} sampled rows - a plausible category to classify" <> keyword_note(column)
        }
      ]
    else
      []
    end
  end

  defp keyword_bonus(column), do: if(keyword_match?(column), do: 5.0, else: 0.0)
  defp keyword_note(column), do: if(keyword_match?(column), do: ", and its name suggests an outcome/label", else: "")
  defp keyword_match?(column), do: Enum.any?(@keywords, &String.contains?(String.downcase(column), &1))
end
