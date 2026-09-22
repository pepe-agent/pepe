defmodule Pepe.Skills.Curator.Status do
  @moduledoc """
  A picture of the curator for a person: is it on, when did it last run and what did it do,
  when will it next run, what is in its care and which of those skills is closest to going
  stale. One data function for every surface (the CLI, the dashboard, the chat tool), so they
  cannot disagree.
  """

  alias Pepe.Skills.Curator
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Stat

  @type row :: %{
          name: String.t(),
          state: String.t(),
          use_count: non_neg_integer(),
          view_count: non_neg_integer(),
          patch_count: non_neg_integer(),
          fail_count: non_neg_integer(),
          idle_days: non_neg_integer()
        }

  @doc "The curator's current picture."
  @spec get(DateTime.t()) :: map()
  def get(now \\ DateTime.utc_now()) do
    state = State.load()
    rows = usage(now)

    %{
      enabled: Settings.enabled?(),
      paused: State.paused?(),
      consolidate: Settings.consolidate?(),
      settings: Settings.all(),
      last_run_at: State.last_run_at(),
      last_run_summary: state["last_run_summary"],
      last_report: state["last_report"],
      run_count: state["run_count"],
      next_run_at: next_run_at(),
      managed: length(rows),
      active: Enum.count(rows, &(&1.state == "active")),
      stale: Enum.count(rows, &(&1.state == "stale")),
      archived: length(Lifecycle.archived()),
      most_idle: Enum.take(rows, 5)
    }
  end

  @doc "Every skill in the curator's care with how much each was used and how long it has sat idle, most idle first."
  @spec usage(DateTime.t()) :: [row()]
  def usage(now \\ DateTime.utc_now()) do
    at = DateTime.to_unix(now)

    Curator.candidates()
    |> Enum.map(fn stat ->
      %{
        name: stat.name,
        state: stat.state,
        use_count: stat.use_count,
        view_count: stat.view_count,
        patch_count: stat.patch_count,
        fail_count: stat.fail_count,
        idle_days: div(max(at - Stat.last_activity_at(stat), 0), 86_400)
      }
    end)
    |> Enum.sort_by(&{-&1.idle_days, &1.name})
  end

  @doc "When the next automatic run is earliest due, or `nil` (never seen, off, or paused)."
  @spec next_run_at() :: DateTime.t() | nil
  def next_run_at do
    with true <- Settings.enabled?() and not State.paused?(),
         %DateTime{} = last <- State.last_run_at() do
      DateTime.add(last, Settings.interval_hours() * 3600)
    else
      _ -> nil
    end
  end

  @doc "The status as plain lines of text (the CLI and the chat tool print these)."
  @spec lines(map()) :: [String.t()]
  def lines(status) do
    [
      "curator: #{headline(status)}",
      "last run: #{last_run(status)}",
      "next run: #{next_run(status)}",
      "in its care: #{status.managed} skill(s) an agent wrote (#{status.active} active, #{status.stale} stale), #{status.archived} archived",
      "thresholds: stale after #{status.settings["stale_after_days"]} days unused, archived after #{status.settings["archive_after_days"]}; " <>
        "model pass #{if status.consolidate, do: "on", else: "off"}"
    ] ++ most_idle(status.most_idle) ++ report(status.last_report)
  end

  defp headline(%{enabled: false}), do: "off"
  defp headline(%{paused: true}), do: "paused"
  defp headline(_), do: "on"

  defp last_run(%{last_run_at: nil}), do: "never"
  defp last_run(%{last_run_at: at, last_run_summary: summary}), do: "#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC - #{summary}"

  defp next_run(%{next_run_at: nil}), do: "none scheduled"

  defp next_run(%{next_run_at: at}),
    do: "#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC, once nothing has been said for #{Settings.min_idle_hours()}h"

  defp most_idle([]), do: []
  defp most_idle(rows), do: ["most idle:" | Enum.map(rows, &"  #{&1.name}  #{&1.state}, idle #{&1.idle_days}d, used #{&1.use_count}x")]

  defp report(nil), do: []
  defp report(path), do: ["last report: #{path}"]
end
