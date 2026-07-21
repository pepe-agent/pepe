defmodule Pepe.Trace.Migration do
  @moduledoc """
  One-time, operator-run import of traces from their old home
  (`<PEPE_HOME>/data/traces/<scope>/<id>.json`, one file per run) into `Pepe.Repo` - see
  `Pepe.Trace`'s moduledoc for why they moved. Not run automatically - see
  `Pepe.Commitments.Migration`'s moduledoc for why.

  Unlike commitments/watches, the source files are never deleted, even on complete
  success - traces are a diagnostic trail, not something safe to lose to a bug in this
  importer. Remove the old `data/traces/` tree by hand once satisfied. Idempotent either
  way: each id is inserted with `on_conflict: :nothing`, so re-running only ever imports
  what a prior run missed.
  """

  alias Pepe.Repo
  alias Pepe.Trace

  @type report :: %{imported: non_neg_integer(), already_present: non_neg_integer(), failed: [{String.t(), term()}]}

  @doc "Import every trace file still under the legacy data/traces/ tree."
  @spec run() :: report()
  def run do
    results =
      for scope <- legacy_scopes(), id <- legacy_ids(scope) do
        {"#{scope}/#{id}", import_one(scope, id)}
      end

    %{
      imported: Enum.count(results, fn {_, r} -> r == {:ok, :inserted} end),
      already_present: Enum.count(results, fn {_, r} -> r == {:ok, :already_present} end),
      failed: for({label, {:error, reason}} <- results, do: {label, reason})
    }
  end

  defp legacy_scopes do
    case File.ls(Trace.dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  defp legacy_ids(scope) do
    case File.ls(Trace.scope_dir(scope)) do
      {:ok, names} ->
        names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.map(&Path.rootname/1) |> Enum.sort()

      _ ->
        []
    end
  end

  defp import_one(scope, id) do
    path = Path.join(Trace.scope_dir(scope), "#{id}.json")

    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      row = %{
        id: map["id"] || id,
        scope: scope,
        at: map["at"] || 0,
        agent: map["agent"],
        session: map["session"],
        source: map["source"],
        prompt: map["prompt"],
        ms: map["ms"],
        outcome: map["outcome"] || %{},
        events: map["events"] || []
      }

      case Repo.insert_all(Pepe.Trace.Entry, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, :inserted}
        {0, _} -> {:ok, :already_present}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
