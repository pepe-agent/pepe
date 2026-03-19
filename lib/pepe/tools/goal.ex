defmodule Pepe.Tools.Goal do
  @moduledoc """
  Set and track a **goal** for the current conversation: a persistent objective and its
  status, so a long or autonomous task keeps a north star across many turns instead of
  reacting turn by turn.

  The goal lives with the session (`Pepe.Session.Focus`). Actions: `set` (an objective,
  and an optional advisory token target), `status` (mark `active` / `paused` / `blocked`
  / `complete`, with an optional note), `show`, and `clear`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Session.Focus

  @statuses ~w(active paused blocked complete)

  @impl true
  def name, do: "goal"

  @impl true
  def spec do
    function(
      "goal",
      """
      Track the objective of this conversation so you stay on task across turns.
      actions:
      - set: give `objective` (what you are trying to achieve). Optional `budget_tokens` \
        is an advisory target to keep the effort proportionate.
      - status: set `status` to one of active|paused|blocked|complete, with an optional \
        `note` (why). Mark `complete` when the objective is met, `blocked` when you are \
        stuck and need the user.
      - show: return the current goal.
      - clear: drop the goal.
      Use `set` at the start of a non-trivial task; `show` to re-orient; `complete` when done.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["set", "status", "show", "clear"]},
          "objective" => %{"type" => "string", "description" => "What you are trying to achieve (for set)."},
          "budget_tokens" => %{"type" => "integer", "description" => "Advisory token target (for set)."},
          "status" => %{"type" => "string", "enum" => @statuses},
          "note" => %{"type" => "string", "description" => "Optional note for a status change."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    case ctx[:session_key] do
      key when is_binary(key) -> dispatch(action, args, key)
      _ -> {:error, "a goal needs a conversation; there is no session here"}
    end
  end

  def run(_args, _ctx), do: {:error, "goal needs an `action`"}

  defp dispatch("set", %{"objective" => objective} = args, key)
       when is_binary(objective) and objective != "" do
    goal =
      %{"objective" => objective, "status" => "active", "at" => now()}
      |> put_budget(args["budget_tokens"])

    Focus.put_goal(key, goal)
    {:ok, "Goal set.\n" <> render(goal)}
  end

  defp dispatch("set", _args, _key), do: {:error, "set needs a non-empty `objective`"}

  defp dispatch("status", %{"status" => status} = args, key) when status in @statuses do
    case Focus.get_goal(key) do
      nil ->
        {:error, "no goal to update; set one first"}

      goal ->
        goal = goal |> Map.put("status", status) |> put_note(args["note"])
        Focus.put_goal(key, goal)
        {:ok, "Goal is now #{status}.\n" <> render(goal)}
    end
  end

  defp dispatch("status", _args, _key),
    do: {:error, "status must be one of: #{Enum.join(@statuses, ", ")}"}

  defp dispatch("show", _args, key) do
    case Focus.get_goal(key) do
      nil -> {:ok, "No goal set for this conversation."}
      goal -> {:ok, render(goal)}
    end
  end

  defp dispatch("clear", _args, key) do
    Focus.clear_goal(key)
    {:ok, "Goal cleared."}
  end

  defp dispatch(other, _args, _key), do: {:error, "unknown action: #{other}"}

  defp put_note(goal, note) when is_binary(note) and note != "", do: Map.put(goal, "note", note)
  defp put_note(goal, _), do: goal

  defp put_budget(goal, n) when is_integer(n) and n > 0, do: Map.put(goal, "budget_tokens", n)
  defp put_budget(goal, _), do: goal

  defp render(goal) do
    budget =
      case goal["budget_tokens"] do
        n when is_integer(n) and n > 0 -> "\nBudget: ~#{n} tokens (target)"
        _ -> ""
      end

    note = if goal["note"], do: "\nNote: #{goal["note"]}", else: ""
    "Goal: #{goal["objective"]}\nStatus: #{goal["status"] || "active"}" <> budget <> note
  end

  defp now, do: System.os_time(:second)
end
