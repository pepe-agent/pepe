defmodule Pepe.Insight.Examples do
  @moduledoc """
  Accumulated rows for `source_kind: "import"` specs - the durable record `insight
  import_rows` writes into, and the path any other producer (an agent that pulled data via
  `bash` + a database CLI for an engine `Pepe.DB` doesn't support natively, or - not wired
  up yet, but the shape doesn't foreclose it - a future `Pepe.Agent.GoalLoop` verdict)
  writes into through the same `import/3`. Gives `Pepe.Insight.Source.row_count/2`
  something to count against for import-sourced specs, so they're schedulable for periodic
  retrain instead of being `train_now`-only.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Pepe.Insight.Spec
  alias Pepe.Repo

  @primary_key {:id, :string, autogenerate: false}
  schema "insight_examples" do
    field :spec_id, :string
    field :agent, :string
    field :features, :map, default: %{}
    field :target, :string
    field :batch_id, :string
    field :inserted_at, :integer
  end

  @max_per_call 5_000
  @max_per_spec 50_000
  # SQLite's compiled-in bind-parameter ceiling (32,766) divided by this schema's 7 insertable
  # columns caps a single INSERT at ~4,680 rows - comfortably under that with a single
  # Repo.insert_all/2 call. @max_per_call rows are chunked into statements this size instead.
  @insert_chunk_size 1_000

  @doc """
  Import a batch of rows for `spec` (a `Pepe.Insight.Spec` with `source_kind: "import"`).
  `rows` is a list of string-keyed maps, each covering `spec.target_column` and every
  `spec.feature_columns` entry - all-or-nothing: the first row missing a required key
  aborts the whole batch (nothing is written), rather than a partial insert. `opts[:replace]`
  (default `false`) clears every prior example for this spec first. Capped at
  #{@max_per_call} rows per call and #{@max_per_spec} examples per spec (oldest pruned past
  the cap, so this table can't grow unbounded).
  """
  @spec import(Spec.t(), [map()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def import(spec, rows, opts \\ [])

  def import(_spec, rows, _opts) when not is_list(rows) or rows == [] do
    {:error, "rows must be a non-empty array"}
  end

  def import(_spec, rows, _opts) when length(rows) > @max_per_call do
    {:error, "at most #{@max_per_call} rows per call (got #{length(rows)})"}
  end

  def import(%Spec{} = spec, rows, opts) do
    with {:ok, prepared} <- prepare(spec, rows) do
      now = System.system_time(:second)
      batch_id = new_id()

      entries =
        Enum.map(prepared, fn {features, target} ->
          %{id: new_id(), spec_id: spec.id, agent: spec.agent, features: features, target: target, batch_id: batch_id, inserted_at: now}
        end)

      {:ok, inserted} = Repo.transaction(fn -> replace_and_insert(spec, entries, opts) end)

      total = count(spec.id)
      {:ok, %{"inserted" => inserted, "total_examples" => total, "min_new_rows" => spec.min_new_rows}}
    end
  end

  # A single Repo.insert_all/2 over @max_per_call rows would exceed SQLite's bind-parameter
  # ceiling - see @insert_chunk_size. Chunked inserts plus the delete/prune above sharing
  # one transaction also makes the whole batch all-or-nothing, instead of a delete or a
  # later chunk failing and leaving a partially-replaced example set.
  defp replace_and_insert(spec, entries, opts) do
    if opts[:replace] do
      from(e in __MODULE__, where: e.spec_id == ^spec.id) |> Repo.delete_all()
    end

    entries
    |> insert_in_chunks()
    |> tap(fn _ -> prune(spec.id) end)
  end

  defp insert_in_chunks(entries) do
    entries
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} = Repo.insert_all(__MODULE__, chunk)
      acc + n
    end)
  end

  @doc """
  Every example for `spec_id`, shaped like a fetched DB row (features merged with the
  target under `target_column`). `target_column` is `nil` for a "clustering" spec (no
  target to predict) - the target is left out of the row entirely rather than merged
  under a `nil` key.
  """
  @spec rows(String.t(), String.t() | nil) :: [map()]
  def rows(spec_id, target_column) do
    from(e in __MODULE__, where: e.spec_id == ^spec_id, order_by: e.inserted_at)
    |> Repo.all()
    |> Enum.map(&merge_target(&1, target_column))
  end

  defp merge_target(example, nil), do: example.features
  defp merge_target(example, target_column), do: Map.put(example.features, target_column, example.target)

  @doc "Count of stored examples for `spec_id`."
  @spec count(String.t()) :: non_neg_integer()
  def count(spec_id), do: from(e in __MODULE__, where: e.spec_id == ^spec_id) |> Repo.aggregate(:count)

  defp prepare(spec, rows) do
    columns = Enum.uniq(List.wrap(spec.target_column) ++ List.wrap(spec.time_column) ++ spec.feature_columns)

    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, idx}, {:ok, acc} ->
      case prepare_row(row, spec, columns, idx) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp prepare_row(row, spec, columns, idx) when is_map(row) do
    case Enum.find(columns, &(not Map.has_key?(row, &1))) do
      nil ->
        features = Map.take(row, Enum.uniq(List.wrap(spec.time_column) ++ spec.feature_columns))
        {:ok, {features, target_value(row, spec.target_column)}}

      missing ->
        {:error, "row #{idx} missing column #{inspect(missing)}"}
    end
  end

  defp prepare_row(_row, _spec, _columns, idx), do: {:error, "row #{idx} must be an object"}

  defp target_value(_row, nil), do: nil
  defp target_value(row, target_column), do: row |> Map.fetch!(target_column) |> to_string()

  defp prune(spec_id) do
    over = count(spec_id) - @max_per_spec

    if over > 0 do
      ids = from(e in __MODULE__, where: e.spec_id == ^spec_id, order_by: e.inserted_at, limit: ^over, select: e.id) |> Repo.all()
      from(e in __MODULE__, where: e.id in ^ids) |> Repo.delete_all()
    end
  end

  defp new_id, do: "insex_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
