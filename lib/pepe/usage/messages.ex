defmodule Pepe.Usage.Messages do
  @moduledoc """
  Append-only counter of customer-originated messages per project per month - the
  source of truth for `Pepe.Config.project_message_limit/1`'s monthly cap.

  Backed by `Pepe.Repo` (SQLite), its own `message_events` table - separate from
  `Pepe.Usage.Log` (the token/cost ledger): one customer message can trigger several
  model calls, so counting `Log` entries would overcount, and mixing entry shapes into
  that table would break its billing summary/invoice math.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Repo
  alias Pepe.Usage.MessageEvent

  @doc """
  Re-point every message event recorded under `old` (a project slug) to `new` - called
  on a project rename (`Pepe.Config.rename_project/2`) so a project's message-count
  history follows it, the same way its workspace directory does.
  """
  @spec rescope_project(String.t(), String.t()) :: :ok
  def rescope_project(old, new) do
    from(m in MessageEvent, where: m.project == ^old) |> Repo.update_all(set: [project: new])
    :ok
  end

  @doc """
  Whether `project` has any message events at all, ever - see
  `Pepe.Usage.Log.any_for_project?/1`'s moduledoc for why `Pepe.Config.rename_project/2`
  checks this against the new slug before renaming.
  """
  @spec any_for_project?(String.t() | nil) :: boolean()
  def any_for_project?(scope) do
    name = scope_name(scope)
    from(m in MessageEvent, where: m.project == ^name) |> Repo.exists?()
  end

  @doc "Record one customer-originated message for `project` (`nil` counts against root)."
  @spec record(String.t() | nil) :: :ok
  def record(project), do: insert(project, false)

  @doc """
  Reset `project`'s counter early, before the natural month boundary - inserts a reset
  marker rather than deleting anything, so the ledger stays a full audit trail; messages
  recorded before the marker just stop counting toward the cap.
  """
  @spec reset(String.t() | nil) :: :ok
  def reset(project), do: insert(project, true)

  defp insert(project, reset?) do
    Repo.insert_all(MessageEvent, [%{project: scope_name(project), at: System.system_time(:second), reset: reset?}])
    :ok
  end

  @doc """
  How many messages `project` has been recorded for since the later of: the start
  of the current billing month, or its last `reset/1` (if any fell within it).
  """
  @spec month_to_date(String.t() | nil) :: non_neg_integer()
  def month_to_date(project) do
    this_month = current_month_entries(project) |> Enum.with_index()

    # Break ties on append order (list position), not the raw second-resolution
    # timestamp - a record and a reset in the same wall-clock second are common
    # (tests, or just a burst of traffic) and would otherwise sort ambiguously.
    last_reset_index =
      this_month
      |> Enum.filter(fn {e, _i} -> e.reset end)
      |> List.last()
      |> case do
        nil -> -1
        {_e, i} -> i
      end

    Enum.count(this_month, fn {e, i} -> !e.reset and i > last_reset_index end)
  end

  @doc "Unix timestamp of `project`'s last reset within the current billing month, or `nil`."
  @spec last_reset_at(String.t() | nil) :: integer() | nil
  def last_reset_at(project) do
    project
    |> current_month_entries()
    |> Enum.filter(& &1.reset)
    |> Enum.map(& &1.at)
    |> case do
      [] -> nil
      ats -> Enum.max(ats)
    end
  end

  # A bounded index-range scan (see the [:project, :at] index) instead of loading the
  # scope's entire history - the reason this moved off "read every month's file ever
  # written". Reuses Pepe.Usage's own current-month boundary math (timezone-aware, same
  # billing-day rule `summary/3`/`invoice/2` use) rather than a second copy of it here.
  defp current_month_entries(project) do
    tz = Config.default_timezone()
    {from_at, to_at, _label} = Pepe.Usage.month_range(nil, tz)
    name = scope_name(project)

    from(m in MessageEvent, where: m.project == ^name and m.at >= ^from_at and m.at < ^to_at, order_by: m.id)
    |> Repo.all()
  end

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope), do: to_string(scope)
end
