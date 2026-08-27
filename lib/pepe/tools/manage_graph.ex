defmodule Pepe.Tools.ManageGraph do
  @moduledoc """
  Define, inspect, and remove `Pepe.Graph` definitions from chat - the conversational
  side of `mix pepe graph`, same dual-exposure pattern as `manage_agent`/`mix pepe
  agent`. Always scoped to the calling agent's own graphs (`ctx[:agent]`); it does not
  manage another agent's graphs.

  Actions: `list`, `get`, `import`, `remove`. See `Pepe.Graph`'s moduledoc for the node
  types (`agent`, `verifier`, `human`, `parallel`, `tool`) and the `{{key}}` templating
  a `prompt`/`ask` can use.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Graph

  @impl true
  def name, do: "manage_graph"

  @impl true
  def spec do
    function(
      "manage_graph",
      """
      Define, inspect, or remove one of your own named graphs - reusable multi-step
      workflows with shared state, a verifier that can send the flow back to an earlier
      step, a pause for a human to answer, parallel research, and direct tool steps.

      actions:
      - list: your own graphs.
      - get: one graph's node/edge structure - needs `graph_name`.
      - import: create or replace a graph - needs `graph_name`, `entry` (the starting
        node id), and `nodes` (see below). Optional `initial_state` (a JSON object of
        starting values) and `max_steps` (default 25, capped at 100). Fails with every
        problem found (unknown targets, missing fields, an unauthorized cross-agent
        reference) if the structure is invalid - fix all of them and try again, don't
        guess which one mattered.
      - remove: delete a graph (past runs of it are kept) - needs `graph_name`.

      Each item in `nodes` is an object with an `id` (lowercase letters/digits/-/_) and
      a `type`:
      - "agent": {id, type: "agent", prompt, next?, agent?}. Calls an agent with
        `prompt` (rendered - see templating below); its reply becomes available to
        every later node as {{id}}. `next` is the following node id; omit it to make
        this the last step. `agent` overrides which agent runs it (defaults to this
        graph's own agent) - if it names an agent other than this one, you must already
        be allowed to message that agent.
      - "verifier": {id, type: "verifier", prompt, verdicts, agent?}. Same call as
        "agent", but its reply must end on a line containing exactly one word from
        `verdicts`' keys (e.g. {"pass": "next_node_id", "fail": "earlier_node_id"}) -
        that word decides where the flow goes next, and a target can be an EARLIER
        node, which is how a real revise loop happens (not just a blind retry - the
        earlier node sees the verifier's critique via {{this_verifier_id}}).
      - "human": {id, type: "human", ask, next?}. No model call - the run pauses and
        waits for a human to answer later (`mix pepe graph resume RUN_ID "their answer"`);
        their raw reply becomes {{id}}.
      - "parallel": {id, type: "parallel", agent, tasks, next?}. Fans `tasks` (a list of
        rendered task strings) out to read-only workers of `agent`, same as the
        `delegate` tool; the combined answer becomes {{id}}.
      - "tool": {id, type: "tool", tool, args, next?, agent?}. Calls one existing tool
        directly (gated exactly like a normal tool call) with `args` (an object of
        rendered string values); its result becomes {{id}}. Cannot name run_code,
        delegate, or run_graph - use the matching node type instead.

      Templating in `prompt`/`ask`/`tasks`/`args` values: {{input}} is the run's input
      string; {{node_id}} reads that node's past reply (fails the run if it hasn't run
      yet - use this only for something guaranteed to have run already); {{node_id?}}
      reads it or falls back to a placeholder (use this for a node that might not have
      run yet, like a loop-back target's own upstream on its first pass);
      {{node_id|default:"..."}} falls back to your own literal text instead.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(list get import remove)},
          "graph_name" => %{"type" => "string", "description" => "Which graph."},
          "entry" => %{"type" => "string", "description" => "For import: the starting node id."},
          "nodes" => %{
            "type" => "array",
            "description" => "For import: the full ordered node list - see the action description above.",
            "items" => %{"type" => "object"}
          },
          "initial_state" => %{"type" => "object", "description" => "For import: starting values for {{key}} references, optional."},
          "max_steps" => %{"type" => "integer", "description" => "For import: safety cap on total steps, default 25, max 100."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => "list"}, ctx) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> {:ok, render_list(Graph.for_agent(agent.name))}
    end
  end

  def run(%{"action" => "get", "graph_name" => name}, ctx), do: with_agent(ctx, &get_one(&1, name))

  def run(%{"action" => "import"} = args, ctx) do
    with_agent(ctx, fn agent ->
      definition = %{
        "name" => args["graph_name"],
        "agent" => agent.name,
        "entry" => args["entry"],
        "nodes" => args["nodes"] || [],
        "state" => args["initial_state"] || %{},
        "max_steps" => args["max_steps"]
      }

      case Graph.import(definition, overwrite: true) do
        {:ok, saved} -> {:ok, "Saved graph #{saved["name"]} (#{length(saved["nodes"])} node(s), entry: #{saved["entry"]})."}
        {:error, {:invalid, problems}} -> {:error, "Invalid graph:\n- " <> Enum.join(problems, "\n- ")}
      end
    end)
  end

  def run(%{"action" => "remove", "graph_name" => name}, ctx) do
    with_agent(ctx, fn agent ->
      case Graph.delete(agent.name, name) do
        :ok -> {:ok, "Removed graph #{name}."}
        {:error, :not_found} -> {:error, "no graph named #{name}"}
      end
    end)
  end

  def run(_args, _ctx), do: {:error, "manage_graph needs an `action` (and usually `graph_name`)"}

  ###
  ### helpers
  ###

  defp with_agent(ctx, fun) do
    case ctx[:agent] do
      nil -> {:error, "no calling agent in context"}
      agent -> fun.(agent)
    end
  end

  defp get_one(agent, name) do
    case Graph.get(agent.name, name) do
      nil -> {:error, "no graph named #{name}"}
      graph -> {:ok, describe(graph)}
    end
  end

  defp describe(graph) do
    nodes =
      Enum.map_join(graph["nodes"], "\n", fn node ->
        target = node["next"] || (node["verdicts"] && inspect(node["verdicts"])) || "(terminal)"
        "  #{node["id"]} (#{node["type"]}) -> #{target}"
      end)

    "graph: #{graph["name"]}\nentry: #{graph["entry"]}\nmax_steps: #{graph["max_steps"]}\nnodes:\n#{nodes}"
  end

  defp render_list([]), do: "No graphs defined yet."

  defp render_list(graphs) do
    Enum.map_join(graphs, "\n", fn g -> "#{g["name"]} (entry: #{g["entry"]}, #{length(g["nodes"])} node(s))" end)
  end
end
