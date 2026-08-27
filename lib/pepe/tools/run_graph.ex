defmodule Pepe.Tools.RunGraph do
  @moduledoc """
  Execute one of your own named `Pepe.Graph` definitions. Returns the run id, its final
  status, and (when `"done"`) the terminal node's output. A run that reaches a `human`
  node comes back `"waiting_human"` with what it's asking - tell the person, and once
  they answer, resolve it with `mix pepe graph resume` or by asking again later (the
  run stays parked; nothing is lost).

  Not concurrent, and refuses to run from inside another graph run
  (`ctx[:graph_run_id]`) - a graph cannot call itself, directly or through a chain of
  calls, the same "workers cannot delegate" bound `delegate` already enforces for its
  own kind of fan-out.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Graph
  alias Pepe.Permissions
  alias Pepe.Watch.Delivery

  @impl true
  def name, do: "run_graph"

  @impl true
  def spec do
    function(
      "run_graph",
      """
      Run one of your own graphs (see manage_graph). Optional `input` seeds {{input}}
      for every node's prompt. Returns the run id and status; a "waiting_human" status
      means the run is paused on a real person's answer - relay what it asked, then
      later resolve it (a human runs `mix pepe graph resume RUN_ID "their answer"`, or
      you can tell them that command).
      """,
      %{
        "type" => "object",
        "properties" => %{
          "graph_name" => %{"type" => "string", "description" => "Which of your graphs to run."},
          "input" => %{"type" => "string", "description" => "Optional seed value for {{input}} in every node's prompt."}
        },
        "required" => ["graph_name"]
      }
    )
  end

  @impl true
  def run(_args, %{graph_run_id: id}) when is_binary(id) do
    {:error, "run_graph cannot be called from inside a graph run - use the matching node type in the graph itself instead"}
  end

  def run(%{"graph_name" => name} = args, ctx) do
    case ctx[:agent] do
      nil ->
        {:error, "no calling agent in context"}

      agent ->
        opts = [
          session_key: ctx[:session_key],
          origin: Delivery.origin_from_ctx(ctx),
          on_event: ctx[:on_event],
          # A tainted calling conversation must not launder itself clean just by
          # starting a fresh run - every node in it starts untrusted too, mirroring
          # `delegate`'s own `untrusted: Permissions.tainted?(ctx)` forwarding.
          untrusted: Permissions.tainted?(ctx)
        ]

        case Graph.run(agent.name, name, args["input"], opts) do
          {:ok, run} -> {:ok, describe(run)}
          {:error, :not_found} -> {:error, "no graph named #{name}"}
        end
    end
  end

  def run(_args, _ctx), do: {:error, "run_graph needs a `graph_name`"}

  ###
  ### helpers
  ###

  defp describe(%{"status" => "waiting_human"} = run) do
    asked = run["history"] |> List.last() |> Map.get("asked", "")
    "run #{run["id"]} is waiting_human at node #{run["current_node"]}: #{asked}"
  end

  defp describe(%{"status" => "done"} = run) do
    "run #{run["id"]} done. Final output (#{run["current_node"]}): #{Map.get(run["state"], run["current_node"], "")}"
  end

  defp describe(%{"status" => "failed"} = run), do: "run #{run["id"]} failed: #{run["error"]}"
end
