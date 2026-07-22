defmodule Pepe.Usage.Migration do
  @moduledoc """
  One-time, operator-run import of the old per-project JSONL usage/message-count ledgers
  (`data/usage/<project>/YYYY-MM.jsonl`, `data/messages/<project>/YYYY-MM.jsonl`) into
  `Pepe.Repo` - see `Pepe.Usage.Log`'s moduledoc for why they moved. Not run
  automatically - see `Pepe.Commitments.Migration`'s moduledoc for why.

  Unlike commitments/watches/traces, a usage entry or message event has no natural id to
  key an idempotent, per-entry import on - two entries can legitimately be identical in
  every field (the same agent making two same-sized calls in the same second). Deduping
  on content risks silently dropping a real billing record, which is a worse failure here
  than anywhere else in this migration.

  So, like `Pepe.Config.Journal.Migration`, idempotency is keyed on the legacy directory's
  presence, not on the table's row count: `Pepe.Usage.Log`/`Pepe.Usage.Messages`' own live
  write paths land rows in these exact tables on every real chat turn, with or without
  this command ever running - by the time an operator gets around to running it, both
  tables have almost certainly already picked up unrelated rows, which would falsely read
  as "already migrated" and permanently block a legacy import that never actually
  happened. A clean, fully successful import (see below) renames `data/usage/`/
  `data/messages/` rather than deleting them - a billing audit trail is safer left
  inspectable than risked on a bug in this importer - and it's that renamed-away absence,
  not an emptiness check, that makes a re-run of this command a safe, instant no-op for a
  table that already has plenty of unrelated, perfectly legitimate rows in it.

  All-or-nothing per table: if any legacy file fails to read/parse, *nothing* is inserted,
  the table is left exactly as it was, and the directory is left in place too - so a retry
  after fixing the bad file behaves exactly like a fresh attempt, not a duplicate-risking
  one (nothing from this run ever made it in to begin with). Only a *fully* successful
  import (every file read, everything inserted) renames the directory, since only then is
  there nothing left in it this importer will ever need to look at again. Rows are
  inserted in chunks inside one transaction (SQLite's own bind parameter ceiling,
  `?1..?32766`, is easy to hit with a single unchunked `insert_all` on a real ledger - 8
  columns puts that around 4000 rows) - a failure partway through (e.g. a row missing a
  required field) rolls the whole transaction back, so the table is either fully populated
  or exactly as it started, never in between.
  """

  alias Pepe.Repo
  alias Pepe.Usage.Log
  alias Pepe.Usage.MessageEvent

  # Comfortably under SQLite's ?1..?32766 bind-parameter ceiling for either schema's
  # column count (8 for usage_entries, 3 for message_events).
  @chunk_size 1000

  @type report :: %{imported: non_neg_integer(), failed: [term()]}

  @doc "Import every legacy usage entry, then every legacy message event."
  @spec run() :: %{usage_entries: report(), message_events: report()}
  def run do
    %{
      usage_entries: import_table(Pepe.Usage.Entry, Log.dir(), Log.scopes_on_disk(), &Log.scope_dir/1, &read_usage_file/1),
      message_events:
        import_table(
          MessageEvent,
          Pepe.Usage.Messages.dir(),
          Pepe.Usage.Messages.scopes_on_disk(),
          &Pepe.Usage.Messages.scope_dir/1,
          &read_message_file/1
        )
    }
  end

  defp import_table(schema, base_dir, scopes, scope_dir, read_file) do
    if File.dir?(base_dir) do
      {oks, fails} =
        scopes
        |> Enum.flat_map(&legacy_files(scope_dir.(&1), &1))
        |> Enum.map(read_file)
        |> Enum.split_with(&match?({:ok, _}, &1))

      if fails != [] do
        %{imported: 0, failed: Enum.map(fails, fn {:error, reason} -> reason end)}
      else
        rows = Enum.flat_map(oks, fn {:ok, entries} -> entries end)

        case insert_all_chunked(schema, rows) do
          :ok ->
            File.rename!(base_dir, imported_dir(base_dir))
            %{imported: length(rows), failed: []}

          {:error, reason} ->
            %{imported: 0, failed: [reason]}
        end
      end
    else
      %{imported: 0, failed: []}
    end
  end

  defp imported_dir(base_dir), do: base_dir <> ".imported"

  defp insert_all_chunked(_schema, []), do: :ok

  defp insert_all_chunked(schema, rows) do
    Repo.transaction(fn ->
      rows |> Enum.chunk_every(@chunk_size) |> Enum.each(&Repo.insert_all(schema, &1))
    end)

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp legacy_files(dir, scope) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&{Path.join(dir, &1), scope})

      _ ->
        []
    end
  end

  defp read_usage_file({path, scope}) do
    with {:ok, body} <- File.read(path) do
      rows =
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map(fn m ->
          %{
            project: scope,
            at: m["at"],
            agent: m["agent"],
            model: m["model"],
            # Same tolerance Pepe.Usage.record/3's own write path already has for a
            # provider reporting a float or omitting a field - a legacy export deserves
            # no less, and an explicit `nil` here would hit the NOT NULL constraint
            # instead of the DB's own `default: 0` (which only applies when the column
            # is omitted from the INSERT entirely, not when NULL is given explicitly).
            in: int(m["in"]),
            out: int(m["out"]),
            sub: m["sub"] == true,
            cached: m["cached"]
          }
        end)

      {:ok, rows}
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  rescue
    e -> {:error, {path, Exception.message(e)}}
  end

  defp read_message_file({path, scope}) do
    with {:ok, body} <- File.read(path) do
      rows =
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map(fn m -> %{project: scope, at: m["at"], reset: m["reset"] == true} end)

      {:ok, rows}
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  rescue
    e -> {:error, {path, Exception.message(e)}}
  end

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(_), do: 0
end
