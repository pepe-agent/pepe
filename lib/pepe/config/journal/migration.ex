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
  re-import.

  So idempotency is keyed on the source *file*, not on the table's row count: an early
  version of this gated on "table still empty," but `Pepe.Config.Journal.record/4` writes
  to this exact table on every ordinary config write from the moment this ships, with or
  without this migration ever having run - by the time an operator gets around to running
  it, the table has almost certainly already picked up unrelated rows (routine day-to-day
  config edits, or even another subsystem's own migration deleting its config.json key in
  the very same `mix pepe config migrate-data` invocation), which would falsely read as
  "already migrated" and permanently block a legacy import that never actually happened.
  A successful run (the whole insert is one transaction: no partial import to leave the
  table in an ambiguous state) renames the source file rather than deleting it - preserved
  for inspection, but its absence is what makes a re-run a safe, instant no-op regardless
  of whatever else has since landed in the table.
  """

  alias Pepe.Config.Journal.Entry
  alias Pepe.Repo

  # Comfortably under SQLite's ?1..?32766 bind-parameter ceiling for this schema's 4
  # columns - a single unchunked insert_all on a real journal history can hit that limit
  # (confirmed empirically: it raises "variable number must be between ?1 and ?32766",
  # not a graceful error), which would make this importer unusable for exactly the
  # installs with the most history to bring over.
  @chunk_size 1000

  @type report :: %{imported: non_neg_integer(), failed: [term()]}

  @doc "Import every line of the legacy config journal file, if it still exists (see the moduledoc)."
  @spec run() :: report()
  def run do
    case File.read(path()) do
      {:ok, body} -> import_body(body)
      {:error, :enoent} -> %{imported: 0, failed: []}
    end
  end

  defp import_body(body) do
    {rows, failed} =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&decode_line/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    rows = Enum.map(rows, fn {:ok, row} -> row end)

    Repo.transaction(fn ->
      if rows != [], do: rows |> Enum.chunk_every(@chunk_size) |> Enum.each(&Repo.insert_all(Entry, &1))
    end)

    # This file's job is done either way: well-formed lines are in, malformed ones are
    # permanently reported below and never retried. Renamed, not deleted, so the trail
    # stays inspectable.
    File.rename!(path(), imported_path())

    %{imported: length(rows), failed: Enum.map(failed, fn {:error, reason} -> reason end)}
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
  defp imported_path, do: path() <> ".imported"
end
