defmodule Pepe.Insight.Source do
  @moduledoc """
  Fetches rows and row counts for a spec, regardless of where they come from - a
  registered Postgres connection (`source_kind: "db"`, via the exact same
  `Pepe.DB.Query.run/3` path `db_query` uses, so RLS/tenant scoping is inherited for free
  and never bypassed) or previously-imported rows (`source_kind: "import"`, via
  `Pepe.Insight.Examples`). Both branches return the same shape
  (`[%{"col" => value}, ...]`), so `Pepe.Insight.Trainer` never branches on which kind of
  spec it's looking at.

  Table/column identifiers embedded in the `"db"` branch's SQL come from an operator/agent
  at `Pepe.Insight.define_spec/1` time, validated there against a strict
  `^[a-zA-Z_][a-zA-Z0-9_]*$` pattern (identifiers can't be bind-parameterized) - this
  module trusts that validation already happened rather than re-checking it.

  A table too large to scan gets a representative random SAMPLE, never the "first N rows"
  a plain `LIMIT` would return (which would systematically favor whatever the table's
  physical/insertion order happens to be - old rows first, for a typical event log). Above
  `@small_scan_limit` rows, `fetch/3` uses Postgres's `TABLESAMPLE SYSTEM`, which is cheap
  (block-approximate, doesn't need to scan every row to pick a sample) rather than `ORDER
  BY random()`, which would force a full scan+sort on a table with hundreds of millions of
  rows. `@sample_cap` bounds the training set size regardless of table size - past a
  certain sample size, more rows stop meaningfully improving a small model, so there is no
  attempt here to "use all of a 400-million-row table."
  """

  alias Pepe.DB.Query
  alias Pepe.Insight.Examples
  alias Pepe.Insight.Spec

  @small_scan_limit 50_000
  @sample_cap 200_000

  @spec fetch(Spec.t(), map(), non_neg_integer() | nil) :: {:ok, [%{String.t() => term()}]} | {:error, term()}
  def fetch(spec, ctx, population \\ nil)
  def fetch(%Spec{source_kind: "db"} = spec, ctx, population), do: db_fetch(spec, ctx, population)
  def fetch(%Spec{source_kind: "import"} = spec, _ctx, _population), do: {:ok, Examples.rows(spec.id, spec.target_column)}

  @spec row_count(Spec.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def row_count(%Spec{source_kind: "db"} = spec, ctx), do: db_count(spec, ctx)
  def row_count(%Spec{source_kind: "import"} = spec, _ctx), do: {:ok, Examples.count(spec.id)}

  defp db_fetch(spec, ctx, population) do
    with {:ok, population} <- resolve_population(spec, ctx, population) do
      sql = fetch_sql(spec, population)

      case Query.run(spec.connection, sql, ctx) do
        {:ok, %{columns: columns, rows: rows}} when is_list(columns) -> {:ok, Enum.map(rows, &row_map(columns, &1))}
        {:ok, %{columns: nil}} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_population(_spec, _ctx, population) when is_integer(population), do: {:ok, population}
  defp resolve_population(spec, ctx, nil), do: db_count(spec, ctx)

  # TABLESAMPLE SYSTEM emits its sampled rows in physical/block order, not randomized order
  # - a bare LIMIT after it would keep whichever sampled rows happen to sit in the
  # physically-first blocks, silently reintroducing the exact table-order bias this whole
  # path exists to avoid (worst when @sample_cap * 3 rows is a sizeable fraction of the
  # table, where sample_percent below clamps near 100). The inner TABLESAMPLE still does
  # the expensive part cheaply (cutting a huge table down to a bounded candidate set
  # without scanning every row); sorting THAT bounded set by random() is what actually
  # makes the final LIMIT a fair random pick instead of "whichever showed up first".
  defp fetch_sql(spec, population) when population > @small_scan_limit do
    "SELECT * FROM (SELECT #{columns_sql(spec)} FROM #{spec.table} TABLESAMPLE SYSTEM (#{sample_percent(population)})) sampled " <>
      "ORDER BY random() LIMIT #{@sample_cap}"
  end

  defp fetch_sql(spec, _population), do: "SELECT #{columns_sql(spec)} FROM #{spec.table} LIMIT #{@small_scan_limit}"

  # A 3x oversample keeps the candidate set comfortably above @sample_cap after
  # TABLESAMPLE's own block-approximate selection, so the final ORDER BY random() LIMIT
  # above has enough rows to pick a genuinely random @sample_cap from.
  defp sample_percent(population) do
    (@sample_cap * 3 * 100 / population) |> min(100.0) |> max(0.01) |> Float.round(4)
  end

  defp db_count(spec, ctx) do
    case Query.run(spec.connection, "SELECT COUNT(*) FROM #{spec.table}", ctx) do
      {:ok, %{rows: [[n]]}} -> {:ok, n}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  # target_column is nil for "clustering" (no target); time_column is nil except for
  # "forecast" - List.wrap drops whichever is absent.
  defp columns_sql(spec) do
    (List.wrap(spec.target_column) ++ List.wrap(spec.time_column) ++ spec.feature_columns) |> Enum.uniq() |> Enum.join(", ")
  end

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()
end
