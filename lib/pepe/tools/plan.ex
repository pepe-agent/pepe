defmodule Pepe.Tools.Plan do
  @moduledoc """
  Maintain a live **plan** for a multi-step task: an ordered checklist of steps, each
  `pending`, `in_progress`, or `done`. Calling `update_plan` replaces the whole list, so
  the model keeps one coherent, visible plan as it works instead of losing track.

  The plan lives with the session (`Pepe.Session.Focus`); the rendered checklist is
  returned (and shown in the chat/trace) so the user can watch progress.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Session.Focus

  @statuses ~w(pending in_progress done)

  @impl true
  def name, do: "update_plan"

  @impl true
  def spec do
    function(
      "update_plan",
      """
      Maintain a checklist for a multi-step task. Pass the FULL ordered list of steps \
      each time (it replaces the previous plan). Mark one step `in_progress` at a time, \
      flip finished steps to `done`, and update as the work evolves. Use this for \
      non-trivial tasks so the plan stays visible and you don't lose track; skip it for \
      trivial one-step requests. Pass an empty `steps` list to clear the plan.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "steps" => %{
            "type" => "array",
            "description" => "The full ordered list of steps.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string"},
                "status" => %{"type" => "string", "enum" => @statuses}
              },
              "required" => ["title"]
            }
          }
        },
        "required" => ["steps"]
      }
    )
  end

  @impl true
  def run(%{"steps" => steps}, ctx) when is_list(steps) do
    case ctx[:session_key] do
      key when is_binary(key) -> update(key, steps)
      _ -> {:error, "a plan needs a conversation; there is no session here"}
    end
  end

  def run(_args, _ctx), do: {:error, "update_plan needs a `steps` list"}

  defp update(key, []) do
    Focus.clear_plan(key)
    {:ok, "Plan cleared."}
  end

  defp update(key, steps) do
    clean = Enum.map(steps, &normalize/1) |> Enum.reject(&is_nil/1)
    Focus.put_plan(key, clean)
    {:ok, render(clean)}
  end

  defp normalize(%{"title" => title} = step) when is_binary(title) and title != "" do
    status = if step["status"] in @statuses, do: step["status"], else: "pending"
    %{"title" => title, "status" => status}
  end

  defp normalize(_), do: nil

  defp render([]), do: "Plan is empty."

  defp render(steps) do
    done = Enum.count(steps, &(&1["status"] == "done"))
    lines = Enum.map_join(steps, "\n", fn s -> "#{box(s["status"])} #{s["title"]}" end)
    "Plan (#{done}/#{length(steps)} done):\n" <> lines
  end

  defp box("done"), do: "[x]"
  defp box("in_progress"), do: "[~]"
  defp box(_), do: "[ ]"
end
