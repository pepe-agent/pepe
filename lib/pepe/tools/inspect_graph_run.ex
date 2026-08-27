defmodule Pepe.Tools.InspectGraphRun do
  @moduledoc """
  Check on a graph run you (or a human) started earlier - its status, which node it's
  on or stopped at, and the per-node history. The conversational counterpart to
  `mix pepe graph inspect`, for when the agent itself needs to check without asking the
  operator to run it.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Graph

  @impl true
  def name, do: "inspect_graph_run"

  @impl true
  def spec do
    function(
      "inspect_graph_run",
      "Check the status and history of a graph run by its id (from run_graph's own reply, or one a human gave you).",
      %{
        "type" => "object",
        "properties" => %{"run_id" => %{"type" => "string", "description" => "The run id, e.g. grun_a1b2c3d4."}},
        "required" => ["run_id"]
      }
    )
  end

  @impl true
  def run(%{"run_id" => run_id}, ctx) do
    case ctx[:agent] do
      nil ->
        {:error, "no calling agent in context"}

      agent ->
        # Scoped the same way `manage_graph`/`run_graph` are - a run id alone must not
        # let one agent read another's (or another project's) run history.
        case Graph.get_run(run_id) do
          %{"agent" => owner} = graph_run when owner == agent.name -> {:ok, describe(graph_run)}
          _ -> {:error, "no run with id #{run_id}"}
        end
    end
  end

  def run(_args, _ctx), do: {:error, "inspect_graph_run needs a `run_id`"}

  defp describe(run) do
    header =
      "graph: #{run["graph_name"]}\nstatus: #{run["status"]}\ncurrent_node: #{run["current_node"]}\nsteps: #{run["steps_taken"]}/#{run["max_steps"]}"

    header = if run["error"], do: header <> "\nerror: #{run["error"]}", else: header

    history =
      Enum.map_join(run["history"], "\n", fn h ->
        "  #{h["node"]} (visit #{h["visit"]}) -> #{h["next"] || "(pending)"}#{if h["verdict"], do: " [#{h["verdict"]}]", else: ""}"
      end)

    header <> "\nhistory:\n" <> history
  end
end
