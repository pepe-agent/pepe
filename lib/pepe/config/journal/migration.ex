defmodule Pepe.Config.Journal.Migration do
  @moduledoc """
  One-time, operator-run import of the old `data/config_journal.jsonl` file into
  `Pepe.Repo` - see `Pepe.Config.Journal`'s moduledoc for why it moved. Not run
  automatically - see `Pepe.Commitments.Migration`'s moduledoc for why.

  Unlike commitments/watches, a journal entry has no natural id to key an idempotent,
  per-entry `on_conflict: :nothing` import on - two entries can legitimately have every
  field identical (the same source making two no-op-adjacent writes in the same second).
  Deduping on content here risks silently dropping a real entry instead of a genuine
  duplicate, which is a worse failure for an audit trail than simply refusing to
  re-import: this only ever runs against an *empty* `config_journal_entries` table, and
  refuses with a clear reason otherwise. The source `.jsonl` file is never deleted (a
  hiccup here should never destroy a still-unread audit trail) - remove it by hand once
  satisfied.
  """

  alias Pepe.Config.Journal.Entry
  alias Pepe.Repo

  # Comfortably under SQLite's ?1..?32766 bind-parameter ceiling for this schema's 4
  # columns - a single unchunked insert_all on a real journal history can hit that limit
  # (confirmed empirically: it raises "variable number must be between ?1 and ?32766",
  # not a graceful error), which would make this importer unusable for exactly the
  # installs with the most history to bring over.
  @chunk_size 1000

  @type report :: %{imported: non_neg_integer(), failed: [term()]} | {:error, :not_empty}

  @doc "Import every line of the legacy config journal file, if the table is still empty."
  @spec run() :: report()
  def run do
    if Repo.aggregate(Entry, :count) > 0 do
      {:error, :not_empty}
    else
      import_file()
    end
  end

  defp import_file do
    case File.read(path()) do
      {:ok, body} ->
        {rows, failed} =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_line/1)
          |> Enum.split_with(&match?({:ok, _}, &1))

        rows = Enum.map(rows, fn {:ok, row} -> row end)
        if rows != [], do: rows |> Enum.chunk_every(@chunk_size) |> Enum.each(&Repo.insert_all(Entry, &1))

        %{imported: length(rows), failed: Enum.map(failed, fn {:error, reason} -> reason end)}

      {:error, :enoent} ->
        %{imported: 0, failed: []}
    end
  end

  defp decode_line(line) do
    with {:ok, %{"at" => at, "source" => source} = map} when is_integer(at) and is_binary(source) <- Jason.decode(line) do
      changed = if is_list(map["changed"]), do: map["changed"], else: []
      {:ok, %{at: at, source: source, changed: changed, external: map["external"] == true}}
    else
      _ -> {:error, {:malformed_line, line}}
    end
  end

  defp path, do: Path.join([Pepe.Config.home(), "data", "config_journal.jsonl"])
end
