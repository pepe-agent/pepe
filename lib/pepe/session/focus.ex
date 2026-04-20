defmodule Pepe.Session.Focus do
  @moduledoc """
  Per-session working state: the current **goal** (a persistent objective + status) and
  **plan** (a step checklist) for a conversation. Kept in the disposable `Pepe.Store`,
  keyed by session, so it survives a restart but is regenerable, not a source of truth.

  The `goal` and `update_plan` tools read and write this; surfaces (dashboard, CLI) can
  read it to show what a session is working toward. `Pepe.Agent.Session` also injects
  `context_line/1` into every non-heartbeat turn, so the model doesn't have to call
  `goal show`/`update_plan` itself just to stay oriented.
  """

  alias Pepe.Store

  @ns :focus

  @type goal :: %{optional(String.t()) => any()}

  @doc "The session's current goal map, or nil."
  def get_goal(nil), do: nil
  def get_goal(key), do: get(key)["goal"]

  @doc "Set the session's goal map."
  def put_goal(key, goal) when is_binary(key), do: update(key, &Map.put(&1, "goal", goal))

  @doc "Clear the session's goal."
  def clear_goal(key) when is_binary(key), do: update(key, &Map.delete(&1, "goal"))

  @doc "The session's current plan (a list of step maps), or nil."
  def get_plan(nil), do: nil
  def get_plan(key), do: get(key)["plan"]

  @doc "Set the session's plan (a list of `%{\"title\", \"status\"}` steps)."
  def put_plan(key, steps) when is_binary(key), do: update(key, &Map.put(&1, "plan", steps))

  @doc "Clear the session's plan."
  def clear_plan(key) when is_binary(key), do: update(key, &Map.delete(&1, "plan"))

  @max_line_chars 500

  @doc """
  A single bounded reminder line summarizing the goal and/or plan, or `nil` when
  neither is set. Meant to be injected fresh into a turn's context and never
  persisted into session history - see `Pepe.Agent.Session`'s goal_reminder/1 - so
  it always reflects the *current* state and can't go stale or pile up across turns.
  """
  @spec context_line(String.t() | nil) :: String.t() | nil
  def context_line(nil), do: nil

  def context_line(key) do
    case {get_goal(key), get_plan(key)} do
      {nil, nil} -> nil
      {goal, nil} -> clip("Goal: " <> goal_summary(goal))
      {nil, plan} -> clip("Plan: " <> plan_summary(plan))
      {goal, plan} -> clip("Goal: " <> goal_summary(goal) <> " | Plan: " <> plan_summary(plan))
    end
  end

  defp goal_summary(goal), do: "#{goal["objective"]} (#{goal["status"] || "active"})"

  defp plan_summary(plan) do
    done = Enum.count(plan, &(&1["status"] == "done"))
    current = Enum.find(plan, &(&1["status"] == "in_progress"))
    now = if current, do: " - now: #{current["title"]}", else: ""
    "#{done}/#{length(plan)} steps done#{now}"
  end

  defp clip(text) do
    if String.length(text) > @max_line_chars,
      do: String.slice(text, 0, @max_line_chars) <> "...",
      else: text
  end

  defp get(key), do: Store.get(@ns, key) || %{}

  defp update(key, fun) do
    new = fun.(get(key))
    Store.put(@ns, key, new)
    new["goal"] || new["plan"] || new
  end
end
