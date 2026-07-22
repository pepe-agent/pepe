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
  than anywhere else in this migration: this only ever imports into *empty* tables, and
  refuses with a clear reason otherwise, the same gate `Pepe.Config.Journal.Migration`
  uses for the same reason. The source files are never deleted, even on success - a
  billing audit trail is safer left stale than risked on a bug in this importer. Remove
  `data/usage/` and `data/messages/` by hand once satisfied.

  All-or-nothing per table: if any legacy file fails to read/parse, *nothing* is inserted
  and the table is left empty - a partial import (some months in, some files unreadable)
  would leave the failed months permanently unrecoverable, since a retry refuses against a
  non-empty table. Rows are inserted in chunks inside one transaction (SQLite's own bind
  parameter ceiling, `?1..?32766`, is easy to hit with a single unchunked `insert_all` on a
  real ledger - 8 columns puts that around 4000 rows) - a failure partway through (e.g. a
  row missing a required field) rolls the whole transaction back, so the table is either
  fully populated or still empty, never in between.
  """

  alias Pepe.Repo
  alias Pepe.Usage.Log
  alias Pepe.Usage.MessageEvent

  # Comfortably under SQLite's ?1..?32766 bind-parameter ceiling for either schema's
  # column count (8 for usage_entries, 3 for message_events).
  @chunk_size 1000

  @type report :: %{imported: non_neg_integer(), failed: [term()]} | {:error, :not_empty}

  @doc "Import every legacy usage entry, then every legacy message event."
  @spec run() :: %{usage_entries: report(), message_events: report()}
  def run do
    %{
      usage_entries: import_table(Pepe.Usage.Entry, Log.scopes_on_disk(), &Log.scope_dir/1, &read_usage_file/1),
      message_events:
        import_table(MessageEvent, Pepe.Usage.Messages.scopes_on_disk(), &Pepe.Usage.Messages.scope_dir/1, &read_message_file/1)
    }
  end

  defp import_table(schema, scopes, scope_dir, read_file) do
    if Repo.aggregate(schema, :count) > 0 do
      {:error, :not_empty}
    else
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
          :ok -> %{imported: length(rows), failed: []}
          {:error, reason} -> %{imported: 0, failed: [reason]}
        end
      end
    end
  end

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
