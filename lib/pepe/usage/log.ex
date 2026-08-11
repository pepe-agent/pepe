defmodule Pepe.Usage.Log do
  @moduledoc """
  Append-only token-usage ledger - the durable record billing is built on.

  Every model call the runtime makes appends one row (project, at, agent, model, in,
  out, sub, cached). Append-only + never-expiring (unlike `Pepe.Store`) because it is the
  audit trail for what a client is charged.

  Backed by `Pepe.Repo` (SQLite), not one JSONL file per project per month - see
  `Pepe.Config.Journal`'s moduledoc for the same reasoning. Every public function here
  still takes/returns the exact same string-keyed maps the old JSONL lines held; the
  atom/string boundary conversion happens entirely inside this module.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Usage.Usage

  @doc """
  Append one usage entry to `project`'s ledger. `entry` carries `at`, `agent`, `model`,
  `in`, `out`, and optionally `sub`/`cached`.
  """
  @spec append(String.t() | nil, map()) :: :ok
  def append(project, entry) do
    row = %{
      project: scope_name(project),
      at: entry["at"],
      agent: entry["agent"],
      model: entry["model"],
      in: entry["in"],
      out: entry["out"],
      sub: entry["sub"] == true,
      cached: entry["cached"],
      run_id: entry["run_id"],
      session: entry["session"],
      source: entry["source"]
    }

    Repo.insert_all(Usage, [row])
    :ok
  end

  @doc """
  Re-point every entry recorded under `old` (a project slug) to `new` - called on a
  project rename (`Pepe.Config.rename_project/2`) so a project's usage history follows
  it, the same way its workspace directory does.
  """
  @spec rescope_project(String.t(), String.t()) :: :ok
  def rescope_project(old, new) do
    from(e in Usage, where: e.project == ^old) |> Repo.update_all(set: [project: new])
    :ok
  end

  @doc """
  Whether `project` has any usage entries at all, ever - `Pepe.Config.rename_project/2`
  checks this against the *new* slug before renaming, so a rename can't silently merge a
  live project's future entries with a different, already-deleted project's retained
  billing history sitting under that same slug (`delete_project/2` never purges usage
  data - see its own moduledoc).
  """
  @spec any_for_project?(String.t() | nil) :: boolean()
  def any_for_project?(scope) do
    name = scope_name(scope)
    from(e in Usage, where: e.project == ^name) |> Repo.exists?()
  end

  @doc "Scopes (projects + root) that have any recorded usage."
  def scopes do
    from(e in Usage, distinct: true, select: e.project, order_by: e.project) |> Repo.all()
  end

  @doc """
  All entries for a scope, each decorated with its `project` (the scope name). Oldest
  first (append order).
  """
  @spec entries(String.t() | nil) :: [map()]
  def entries(scope) do
    name = scope_name(scope)
    from(e in Usage, where: e.project == ^name, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)
  end

  @doc "All entries across the given scopes (or all scopes when `:all`)."
  @spec entries_for(:all | [String.t()]) :: [map()]
  def entries_for(:all), do: from(e in Usage, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)

  def entries_for(list) when is_list(list) do
    from(e in Usage, where: e.project in ^list, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)
  end

  @doc """
  Entries for a scope with `at` in `[from, to)` (unix seconds) - a bounded index-range
  scan (see the `[:project, :at]` index) instead of loading the scope's entire history,
  the reason this moved off "read every month's file ever written".
  """
  @spec entries_between(String.t() | nil, integer(), integer()) :: [map()]
  def entries_between(scope, from_at, to_at) do
    name = scope_name(scope)

    from(e in Usage, where: e.project == ^name and e.at >= ^from_at and e.at < ^to_at, order_by: e.id)
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc """
  Entries for a scope with `after_id < id <= up_to_id` (or just `id > after_id` when
  `up_to_id` is `nil`) - unambiguous even when several entries land in the same
  wall-clock second (unlike `entries_between/3`'s `at`, which only has second
  resolution). What `Pepe.Usage.Prepaid` settles a balance checkpoint against; the upper
  bound lets it settle up to a snapshot it took first, so an entry written concurrently,
  mid-settle, is simply deferred to the next settle instead of silently skipped (it
  would otherwise never be billed: past the old checkpoint, but also past a new one
  taken *after* it existed).
  """
  @spec entries_after_id(String.t() | nil, integer(), integer() | nil) :: [map()]
  def entries_after_id(scope, after_id, up_to_id \\ nil) do
    name = scope_name(scope)
    query = from(e in Usage, where: e.project == ^name and e.id > ^after_id, order_by: e.id)
    query = if up_to_id, do: from(e in query, where: e.id <= ^up_to_id), else: query

    query |> Repo.all() |> Enum.map(&to_map/1)
  end

  @doc "The highest entry id recorded for a scope so far, or 0 if it has none yet."
  @spec latest_id(String.t() | nil) :: integer()
  def latest_id(scope) do
    name = scope_name(scope)
    from(e in Usage, where: e.project == ^name, select: max(e.id)) |> Repo.one() || 0
  end

  defp to_map(%Usage{} = e) do
    base = %{
      "id" => e.id,
      "at" => e.at,
      "agent" => e.agent,
      "model" => e.model,
      "in" => e.in,
      "out" => e.out,
      "project" => e.project
    }

    base = if e.sub, do: Map.put(base, "sub", true), else: base
    base = if e.cached && e.cached > 0, do: Map.put(base, "cached", e.cached), else: base

    ~w(run_id session source)a
    |> Enum.reduce(base, fn field, acc ->
      case Map.fetch!(e, field) do
        nil -> acc
        value -> Map.put(acc, to_string(field), value)
      end
    end)
  end

  @doc """
  Every entry belonging to one run (one inbound message), oldest first - the several model
  calls an agent made while answering it. Empty for a run recorded before entries carried a
  `run_id`.
  """
  @spec entries_for_run(:all | [String.t()] | String.t() | nil, String.t()) :: [map()]
  def entries_for_run(scope, run_id) when is_binary(run_id) do
    Usage
    |> scope_query(scope)
    |> then(&from(e in &1, where: e.run_id == ^run_id, order_by: e.id))
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc """
  Every entry belonging to any of `run_ids`, oldest first - one query for a whole page of
  runs, rather than one per run.
  """
  @spec entries_for_runs(:all | [String.t()] | String.t() | nil, [String.t()]) :: [map()]
  def entries_for_runs(_scope, []), do: []

  def entries_for_runs(scope, run_ids) when is_list(run_ids) do
    Usage
    |> scope_query(scope)
    |> then(&from(e in &1, where: e.run_id in ^run_ids, order_by: e.id))
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc """
  Entries for a scope, **newest first**, narrowed by any of `:agent`, `:model`, `:source`,
  `:session`, `:run_id` (exact), `:from`/`:to` (unix seconds, `[from, to)`), `:cursor` (see
  below) and `:limit` (default 100).

  Newest-first and capped, unlike `entries/1`, because this backs a paged API read rather
  than the aggregation pass, which needs the whole history in append order.

  Paging runs on the row id, not on `at`. `at` has one-second granularity, so a page
  boundary that lands inside a busy second would either lose the rows sharing it (with an
  exclusive cursor) or repeat them (with an inclusive one). The id is append order, which is
  time order for a ledger only ever written to at the end, and it is unique.
  """
  @spec recent(:all | [String.t()] | String.t() | nil, keyword()) :: [map()]
  def recent(scope, opts \\ []) do
    scope
    |> narrowed(opts)
    |> cursor(opts[:cursor])
    |> then(&from(e in &1, order_by: [desc: e.id], limit: ^(opts[:limit] || 100)))
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc """
  Entries for a scope in append order and uncapped, narrowed by the same options `recent/2`
  takes (minus `:cursor`/`:limit`, which are paging, not filtering).

  This is what aggregation reads: `Pepe.Usage.summary/3` has to see every entry in the
  window it is summing, so it cannot go through the paged read.
  """
  @spec filtered(:all | [String.t()] | String.t() | nil, keyword()) :: [map()]
  def filtered(scope, opts \\ []) do
    scope
    |> narrowed(opts)
    |> then(&from(e in &1, order_by: e.id))
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  defp narrowed(scope, opts) do
    Usage
    |> scope_query(scope)
    |> equals(:agent, opts[:agent])
    |> equals(:model, opts[:model])
    |> equals(:source, opts[:source])
    |> equals(:session, opts[:session])
    |> equals(:run_id, opts[:run_id])
    |> at_least(opts[:from])
    |> below(opts[:to])
  end

  defp cursor(query, nil), do: query
  defp cursor(query, id), do: from(e in query, where: e.id < ^id)

  defp scope_query(query, :all), do: query
  defp scope_query(query, list) when is_list(list), do: from(e in query, where: e.project in ^list)

  defp scope_query(query, scope) do
    name = scope_name(scope)
    from(e in query, where: e.project == ^name)
  end

  defp equals(query, _field, nil), do: query
  defp equals(query, :agent, v), do: from(e in query, where: e.agent == ^v)
  defp equals(query, :model, v), do: from(e in query, where: e.model == ^v)
  defp equals(query, :source, v), do: from(e in query, where: e.source == ^v)
  defp equals(query, :session, v), do: from(e in query, where: e.session == ^v)
  defp equals(query, :run_id, v), do: from(e in query, where: e.run_id == ^v)

  defp at_least(query, nil), do: query
  defp at_least(query, at), do: from(e in query, where: e.at >= ^at)

  defp below(query, nil), do: query
  defp below(query, at), do: from(e in query, where: e.at < ^at)

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope), do: to_string(scope)
end
