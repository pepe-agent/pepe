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
  alias Pepe.Usage.Entry

  @doc "Root directory holding the legacy, pre-migration per-project usage ledger files."
  def dir, do: Path.join([Config.home(), "data", "usage"])

  @doc "The legacy directory for one scope (`nil`/`\"root\"` -> `root/`)."
  def scope_dir(scope), do: Path.join(dir(), scope_name(scope))

  @doc "Scopes with a legacy, pre-migration ledger directory still on disk - for `Pepe.Usage.Migration`."
  def scopes_on_disk do
    case File.ls(dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

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
      cached: entry["cached"]
    }

    Repo.insert_all(Entry, [row])
    :ok
  end

  @doc """
  Re-point every entry recorded under `old` (a project slug) to `new` - called on a
  project rename (`Pepe.Config.rename_project/2`) so a project's usage history follows
  it, the same way its workspace directory does.
  """
  @spec rescope_project(String.t(), String.t()) :: :ok
  def rescope_project(old, new) do
    from(e in Entry, where: e.project == ^old) |> Repo.update_all(set: [project: new])
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
    from(e in Entry, where: e.project == ^name) |> Repo.exists?()
  end

  @doc "Scopes (projects + root) that have any recorded usage."
  def scopes do
    from(e in Entry, distinct: true, select: e.project, order_by: e.project) |> Repo.all()
  end

  @doc """
  All entries for a scope, each decorated with its `project` (the scope name). Oldest
  first (append order).
  """
  @spec entries(String.t() | nil) :: [map()]
  def entries(scope) do
    name = scope_name(scope)
    from(e in Entry, where: e.project == ^name, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)
  end

  @doc "All entries across the given scopes (or all scopes when `:all`)."
  @spec entries_for(:all | [String.t()]) :: [map()]
  def entries_for(:all), do: from(e in Entry, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)

  def entries_for(list) when is_list(list) do
    from(e in Entry, where: e.project in ^list, order_by: e.id) |> Repo.all() |> Enum.map(&to_map/1)
  end

  @doc """
  Entries for a scope with `at` in `[from, to)` (unix seconds) - a bounded index-range
  scan (see the `[:project, :at]` index) instead of loading the scope's entire history,
  the reason this moved off "read every month's file ever written".
  """
  @spec entries_between(String.t() | nil, integer(), integer()) :: [map()]
  def entries_between(scope, from_at, to_at) do
    name = scope_name(scope)

    from(e in Entry, where: e.project == ^name and e.at >= ^from_at and e.at < ^to_at, order_by: e.id)
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  defp to_map(%Entry{} = e) do
    base = %{"at" => e.at, "agent" => e.agent, "model" => e.model, "in" => e.in, "out" => e.out, "project" => e.project}
    base = if e.sub, do: Map.put(base, "sub", true), else: base
    if e.cached && e.cached > 0, do: Map.put(base, "cached", e.cached), else: base
  end

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope), do: to_string(scope)
end
