defmodule Pepe.Budget.Alert do
  @moduledoc """
  The soft budget alert: when a project crosses its alert threshold (default 80%, before the hard
  spend cap stops it), warn whoever is actively using it - on whatever channel they are on.

  Deliberately channel-agnostic. The core decides *that* an alert is due; delivery goes through
  `Pepe.Watch.Delivery`, the same router watches and reminders use, so it reaches a Telegram chat, a
  live dashboard/widget session, or the TUI without this module knowing anything about them (a new
  surface gets budget alerts for free). It runs on the app's global scheduler tick, not inside any
  one gateway. Deduped once per project per month via the disposable store. The dashboard shows the
  same state as a live badge, for the pull surface.
  """

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Project
  alias Pepe.Store
  alias Pepe.Usage
  alias Pepe.Watch.Delivery

  @dedup_ttl 40 * 24 * 3600

  @doc """
  Check every project with active sessions and fire a one-time alert for any that just crossed its
  soft threshold. Idempotent within a month; safe to call every minute.
  """
  @spec check() :: :ok
  def check do
    SessionSupervisor.list()
    |> Enum.group_by(&session_project/1)
    |> Enum.each(fn {project, keys} -> maybe_alert(project, keys) end)
  end

  defp maybe_alert(project, keys) do
    if Usage.near_budget?(project) and due?(project) do
      mark(project)
      text = alert_text(project)
      # Log always (an operator-visible record), then reach each active session on its own channel.
      Delivery.deliver(%{"channel" => "log", "key" => "budget:#{project || "default"}"}, text)

      keys
      |> Enum.map(&Delivery.origin_from_ctx(%{session_key: &1}))
      |> Enum.uniq()
      |> Enum.each(&Delivery.deliver(&1, text))
    end
  end

  # The project a live session belongs to, via the agent bound to it. `nil` (the default scope) is a
  # real, valid grouping key.
  defp session_project(key) do
    case safe_status(key) do
      %{agent: agent} when is_binary(agent) -> Project.of(agent)
      _ -> nil
    end
  end

  defp safe_status(key) do
    Session.status(key)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp due?(project), do: Store.get(:budget_alert, dedup_key(project)) == nil
  defp mark(project), do: Store.put(:budget_alert, dedup_key(project), true, ttl: @dedup_ttl)

  # Keyed by month so the alert can fire again next month without a manual reset.
  defp dedup_key(project) do
    {y, m, _} = Date.utc_today() |> Date.to_erl()
    "#{project || "default"}:#{y}-#{m}"
  end

  defp alert_text(project) do
    pct = round((Usage.budget_ratio(project) || 0) * 100)
    spent = Usage.format_cost(Usage.month_to_date(project))
    budget = Usage.format_cost(Config.project_budget(project))

    "⚠️ Budget alert: #{project || "default"} is at #{pct}% of this month's budget (#{spent} / #{budget}). " <>
      "It stops accepting work at 100%."
  end
end
