defmodule Pepe.Tools.Review do
  @moduledoc """
  List, approve or reject **autonomous writes staged for review** (`Pepe.Approval`) from
  chat - the conversational side of `pepe review`. When `review_writes` is on, memory and
  skill edits made by background consolidation are queued instead of applied; this lets
  an operator clear the queue by talking to the agent, on any surface.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "review"

  @impl true
  def spec do
    function(
      "review",
      "List, approve or reject autonomous writes staged for review (memory/skill changes queued when review_writes is on). Use action=list to see what's pending, then action=approve or action=reject with the id.",
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["list", "approve", "reject"], "description" => "what to do"},
          "id" => %{"type" => "string", "description" => "the pending write id (required for approve/reject)"}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => "list"}, _ctx), do: {:ok, render_list()}

  def run(%{"action" => "approve", "id" => id}, _ctx) when is_binary(id) do
    case Pepe.Approval.approve(id) do
      {:ok, _} -> {:ok, "Approved #{id}; the change was applied."}
      {:error, :not_found} -> {:ok, "No pending write with id #{id}."}
    end
  end

  def run(%{"action" => "reject", "id" => id}, _ctx) when is_binary(id) do
    case Pepe.Approval.reject(id) do
      :ok -> {:ok, "Rejected #{id}; discarded, nothing was written."}
      {:error, :not_found} -> {:ok, "No pending write with id #{id}."}
    end
  end

  def run(_, _), do: {:error, "action must be list, approve or reject (approve/reject need an id)"}

  defp render_list do
    case Pepe.Approval.list() do
      [] ->
        "Nothing is waiting for review."

      entries ->
        "Writes awaiting review:\n" <>
          Enum.map_join(entries, "\n", fn e ->
            args = get_in(e, ["tool_call", "function", "arguments"]) || ""
            "• #{e["id"]}  #{e["tool"]} by #{e["agent"]}: #{String.slice(to_string(args), 0, 120)}"
          end)
    end
  end
end
