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
  """

  alias Pepe.Repo
  alias Pepe.Usage.Log
  alias Pepe.Usage.MessageEvent

  @type report :: %{imported: non_neg_integer(), failed: [term()]} | {:error, :not_empty}

  @doc "Import every legacy usage entry, then every legacy message event."
  @spec run() :: %{usage_entries: report(), message_events: report()}
  def run do
    %{
      usage_entries: import_usage(),
      message_events: import_messages()
    }
  end

  defp import_usage do
    if Repo.aggregate(Pepe.Usage.Entry, :count) > 0 do
      {:error, :not_empty}
    else
      {rows, failed} =
        Log.scopes_on_disk()
        |> Enum.flat_map(&legacy_files(Log.scope_dir(&1), &1))
        |> Enum.map(&read_usage_file/1)
        |> Enum.split_with(&match?({:ok, _}, &1))

      rows = Enum.flat_map(rows, fn {:ok, entries} -> entries end)
      if rows != [], do: Repo.insert_all(Pepe.Usage.Entry, rows)
      %{imported: length(rows), failed: Enum.map(failed, fn {:error, reason} -> reason end)}
    end
  end

  defp import_messages do
    if Repo.aggregate(MessageEvent, :count) > 0 do
      {:error, :not_empty}
    else
      {rows, failed} =
        Pepe.Usage.Messages.scopes_on_disk()
        |> Enum.flat_map(&legacy_files(Pepe.Usage.Messages.scope_dir(&1), &1))
        |> Enum.map(&read_message_file/1)
        |> Enum.split_with(&match?({:ok, _}, &1))

      rows = Enum.flat_map(rows, fn {:ok, entries} -> entries end)
      if rows != [], do: Repo.insert_all(MessageEvent, rows)
      %{imported: length(rows), failed: Enum.map(failed, fn {:error, reason} -> reason end)}
    end
  end

  defp legacy_files(dir, scope) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
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
            in: m["in"],
            out: m["out"],
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
end
