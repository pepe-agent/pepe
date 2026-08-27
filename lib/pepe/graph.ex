defmodule Pepe.Graph do
  @moduledoc """
  A named, durable definition of nodes and edges - the "graph engineering" pattern this
  fills in alongside `Pepe.Flow` (linear literal replay), `delegate` (parallel isolated
  fan-out), and `run_code` (branching inside one execution): state that survives across
  SEPARATE model calls, and a `verifier` node that can route the flow back to an earlier
  node instead of just retrying.

  ## Node/edge shape

  A definition is plain data - no DSL, no parser. `nodes` is an ordered list of maps,
  each one of five types:

    * `"agent"` - `%{"id" => id, "agent" => name?, "prompt" => template, "next" => id?}`.
      Calls `Pepe.Agent.Runtime.converse/3`; the reply is written to `state[id]`. No
      `"next"` means this node is terminal.
    * `"verifier"` - `%{"id" => id, "agent" => name?, "prompt" => template, "verdicts" =>
      %{word => id_or_end}}`. Same call as `"agent"`, but the reply must end on a line
      matching exactly one verdict word (see `Pepe.Graph.Prompt.verdict/2`) - the target
      may be an earlier node, which is how a revise-loop happens.
    * `"human"` - `%{"id" => id, "ask" => template, "next" => id?}`. No model call: the
      run persists `status: "waiting_human"` and returns; a human's later reply (via
      `resume/2`) becomes `state[id]`.
    * `"parallel"` - `%{"id" => id, "agent" => name, "tasks" => [template, ...], "next" =>
      id?}`. Calls the existing `delegate` tool with the rendered tasks; the combined
      answer is written to `state[id]`.
    * `"tool"` - `%{"id" => id, "agent" => name?, "tool" => tool_name, "args" => %{key =>
      template}, "next" => id?}`. Gated through `Pepe.Permissions.gate/3` exactly like a
      direct tool call, then executed.

  `template` strings use `Pepe.Graph.Prompt`'s minimal `{{key}}` substitution:
  `{{input}}` is the run's input, `{{node_id}}` reads `state[node_id]` (missing key fails
  the run - it's almost always a typo), `{{node_id?}}` falls back to a fixed placeholder
  on a miss, `{{node_id|default:"..."}}` falls back to a literal.

  Every reference to another node - `next`, a `verdicts` target, or a `{{ref}}` inside a
  template - is validated against the definition's own node ids at `import/2` time, so a
  run can never route to something that doesn't exist; the only failures possible at run
  time are a model/tool error, a bad verdict, a still-unbound required reference, or the
  step cap.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Graph.Definition
  alias Pepe.Graph.Prompt
  alias Pepe.Graph.Run
  alias Pepe.Graph.Runner
  alias Pepe.Repo
  alias Pepe.Tools

  @reserved_ids ~w(input end)
  @id_pattern ~r/^[a-z0-9_-]+$/
  @denied_tools ~w(run_code delegate run_graph)
  @max_steps_range 1..100

  @doc "Every graph for one agent (a bare handle resolves the same as a full one), sorted by name."
  @spec for_agent(String.t()) :: [map()]
  def for_agent(agent_ref) do
    case canonical_agent(agent_ref) do
      nil -> []
      agent -> from(g in Definition, where: g.agent == ^agent, order_by: g.name) |> Repo.all() |> Enum.map(&to_map/1)
    end
  end

  @doc "Fetch one graph definition by agent + name, or `nil`."
  @spec get(String.t(), String.t()) :: map() | nil
  def get(agent_ref, name) do
    case canonical_agent(agent_ref) do
      nil -> nil
      agent -> Repo.get_by(Definition, agent: agent, name: name) |> map_or_nil()
    end
  end

  @doc "Delete a graph definition. Existing runs are kept untouched (they hold their own frozen snapshot)."
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(agent_ref, name) do
    case canonical_agent(agent_ref) do
      nil ->
        {:error, :not_found}

      agent ->
        case Repo.get_by(Definition, agent: agent, name: name) do
          nil -> {:error, :not_found}
          entry -> Repo.delete!(entry) && :ok
        end
    end
  end

  @doc """
  Validate and persist a graph definition (upsert on `[agent, name]`). `definition` is a
  string-keyed map with `"name"`, `"agent"`, `"entry"`, `"nodes"`, and optionally
  `"state"`/`"max_steps"`. Returns `{:ok, saved}` or `{:error, reason}` - `reason` is
  either `:already_exists` (pass `overwrite: true` to replace) or `{:invalid, [String.t()]}`,
  a list of every problem found, not just the first.
  """
  @spec import(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(definition, opts \\ [])

  # `mix pepe graph import FILE.json` hands in whatever `Jason.decode/1` returned - valid
  # JSON that isn't an object (a bare string, array, number...) would otherwise crash on
  # `definition["agent"]` a few lines down instead of failing the import cleanly.
  def import(definition, _opts) when not is_map(definition) do
    {:error, {:invalid, ["the graph definition must be a JSON object"]}}
  end

  def import(definition, opts) do
    agent = Config.get_agent(definition["agent"])

    cond do
      is_nil(agent) ->
        {:error, {:invalid, ["unknown agent #{inspect(definition["agent"])}"]}}

      # Checked before `get/2` below ever runs: `Repo.get_by`/a keyword filter raises on a
      # bare `nil` value (Ecto forbids it - it wants `is_nil/1` spelled out, precisely
      # because a nil comparison is normally not what the caller meant), so a nameless
      # definition must be refused here first, not left to crash the already-exists check.
      name_problems(definition["name"]) != [] ->
        {:error, {:invalid, name_problems(definition["name"])}}

      not is_nil(get(agent.name, definition["name"])) and opts[:overwrite] != true ->
        {:error, :already_exists}

      true ->
        state_keys = definition["state"] |> stringify_state() |> Map.keys()
        errors = validate_nodes(definition["nodes"], definition["entry"], agent, state_keys)

        case errors do
          [] -> save(agent.name, definition, opts[:overwrite] == true)
          errors -> {:error, {:invalid, errors}}
        end
    end
  end

  defp name_problems(name) when is_binary(name) and name != "", do: []
  defp name_problems(_name), do: ["a graph needs a non-empty \"name\""]

  defp stringify_state(state) when is_map(state), do: state
  defp stringify_state(_state), do: %{}

  # The `not is_nil(get(...)) and not overwrite? -> :already_exists` check in `import/2`
  # is a plain read, not a lock - two concurrent imports of the same never-seen-before
  # name can both read "doesn't exist yet" and both reach here. `on_conflict: :nothing`
  # (rather than always `:replace`) makes the actual write the enforcement point for a
  # non-overwrite import: the loser's insert becomes a no-op instead of silently replacing
  # what the winner just saved, and its 0-rows-affected result is what turns into the
  # `:already_exists` this caller expected all along.
  defp save(agent_name, definition, overwrite?) do
    now = System.system_time(:second)
    existing = Repo.get_by(Definition, agent: agent_name, name: definition["name"])

    row = %{
      id: (existing && existing.id) || new_id(),
      name: definition["name"],
      agent: agent_name,
      entry: definition["entry"],
      nodes: definition["nodes"],
      state: definition["state"] || %{},
      max_steps: clamp_max_steps(definition["max_steps"]),
      created_at: (existing && existing.created_at) || now,
      updated_at: now
    }

    conflict = if overwrite?, do: {:replace, [:entry, :nodes, :state, :max_steps, :updated_at]}, else: :nothing

    case Repo.insert_all(Definition, [row], on_conflict: conflict, conflict_target: [:agent, :name]) do
      {0, _} when not overwrite? -> {:error, :already_exists}
      _ -> {:ok, get(agent_name, definition["name"])}
    end
  end

  ###
  ### running / resuming
  ###

  @doc """
  Run a graph synchronously to completion, a pause (`status: "waiting_human"`), or a
  failure. `opts[:session_key]` + `opts[:origin]` (the full origin map,
  `Pepe.Watch.Delivery`'s shape) are set when started from inside a live conversation,
  so a later `resume/2` can hand the eventual result back into it; `opts[:on_event]`
  passes through to every node's
  `Runtime.converse/3` call.
  """
  @spec run(String.t(), String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def run(agent_ref, name, input, opts \\ []) do
    case get(agent_ref, name) do
      nil -> {:error, :not_found}
      definition -> {:ok, Runner.start(definition, input, opts)}
    end
  end

  @doc "Resume a `waiting_human` run with a human's raw text reply."
  @spec resume(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(run_id, human_reply), do: Runner.resume(run_id, human_reply)

  @doc "Runs, newest first, optionally scoped to one agent. An unknown agent scopes to nothing, never to everyone's."
  @spec runs(keyword()) :: [map()]
  def runs(opts \\ []) do
    case {opts[:agent], opts[:agent] && canonical_agent(opts[:agent])} do
      # `opts[:agent]` was given but didn't resolve to a real agent - an unknown/misspelled
      # handle must scope to nothing, not silently fall through to every agent's runs.
      {requested, nil} when not is_nil(requested) ->
        []

      {_requested, agent} ->
        query = from(r in Run, order_by: [desc: r.created_at])
        query = if agent, do: from(r in query, where: r.agent == ^agent), else: query
        query = if opts[:limit], do: from(r in query, limit: ^opts[:limit]), else: query
        query |> Repo.all() |> Enum.map(&run_to_map/1)
    end
  end

  @doc "Fetch one run by id, or `nil`."
  @spec get_run(String.t()) :: map() | nil
  def get_run(run_id), do: Repo.get(Run, run_id) |> map_or_nil(&run_to_map/1)

  @doc """
  A `running`/`waiting_human` run whose `updated_at` is older than 15 minutes almost
  certainly died mid-node (a BEAM crash, a killed process) - flagged lazily at read
  time, same as `Pepe.Permissions.PendingApprovals`' expiry check, never a background
  sweeper.
  """
  @spec stale?(map()) :: boolean()
  def stale?(%{"status" => status, "updated_at" => updated_at}) when status in ["running", "waiting_human"] do
    System.system_time(:second) - updated_at > 15 * 60
  end

  def stale?(_run), do: false

  ###
  ### validation
  ###

  defp validate_nodes(nodes, entry, owner, state_keys) when is_list(nodes) and nodes != [] do
    # `nodes` is whatever JSON a file, a CLI arg, or a model's own `manage_graph` call
    # handed in - a non-map entry (a bare string, a number...) must be caught here, before
    # `& &1["id"]` below or anything else in this module ever touches it, or it crashes
    # instead of failing the import cleanly.
    case Enum.reject(nodes, &is_map/1) do
      [] -> validate_map_nodes(nodes, entry, owner, state_keys)
      _bad -> ["every node must be a JSON object"]
    end
  end

  defp validate_nodes(_nodes, _entry, _owner, _state_keys), do: ["a graph needs at least one node"]

  defp validate_map_nodes(nodes, entry, owner, state_keys) do
    ids = Enum.map(nodes, & &1["id"])
    # A {{ref}} may legitimately name either a node id (populated once that node runs) or
    # a key already present in the graph's own initial `state` defaults (populated from
    # the start) - both live in the same `state` map at run time.
    refable = ids ++ state_keys

    []
    |> check(duplicate_ids(ids), &"duplicate node id #{inspect(&1)}")
    |> check(reserved_ids(ids), &"node id #{inspect(&1)} is reserved")
    |> check(if(entry in ids, do: [], else: [entry]), &"unknown entry node #{inspect(&1)}")
    |> check(invalid_id_shapes(ids), &"node id #{inspect(&1)} must match ^[a-z0-9_-]+$")
    |> then(&Enum.reduce(nodes, &1, fn node, acc -> validate_node(node, ids, refable, owner, acc) end))
  end

  defp validate_node(node, ids, refable, owner, errors) do
    id = node["id"]

    errors
    |> check(dangling_targets(node, ids), &"node #{inspect(id)}: unknown target #{inspect(&1)}")
    |> check(unbound_template_refs(node, refable), &"node #{inspect(id)}: {{#{&1}}} references no node or state default")
    |> check(unauthorized_node_agent(node, owner), &"node #{inspect(id)}: #{&1}")
    |> validate_node_type(node, owner)
  end

  # A node naming an agent OTHER than the graph's own owner must be someone the owner
  # is allowed to address - the exact `can_message` boundary `delegate`'s peer/2 and
  # `send_to_agent` already enforce. Without this, a graph would be a way to route an
  # agent-to-agent call around that boundary instead of through it.
  #
  # `name` is whatever the node's author typed - almost always the bare label, not the
  # full `project/name` handle `owner.name` and `owner.can_message` are stored as - so
  # this resolves it to its own canonical handle before comparing. Comparing the raw
  # strings would treat a node that names its OWN owning agent by its correct bare
  # label as if it were addressing someone else entirely.
  defp unauthorized_node_agent(%{"agent" => name}, owner) when is_binary(name) do
    case Config.get_agent(name) do
      nil ->
        ["names an unknown agent #{inspect(name)}"]

      %{name: canonical} when canonical == owner.name ->
        []

      %{name: canonical} ->
        if canonical in (owner.can_message || []) do
          []
        else
          ["#{owner.name} is not allowed to address #{canonical} (not in can_message)"]
        end
    end
  end

  defp unauthorized_node_agent(_node, _owner), do: []

  defp validate_node_type(errors, %{"type" => "agent"} = node, _owner) do
    errors
    |> check_bool(is_binary(node["prompt"]) and node["prompt"] != "", "node #{inspect(node["id"])}: an agent node needs a \"prompt\"")
    |> check_bool(is_nil(node["verdicts"]), "node #{inspect(node["id"])}: an agent node cannot have verdicts")
  end

  defp validate_node_type(errors, %{"type" => "verifier"} = node, _owner) do
    errors
    |> check_bool(is_binary(node["prompt"]) and node["prompt"] != "", "node #{inspect(node["id"])}: a verifier node needs a \"prompt\"")
    |> check_bool(
      is_map(node["verdicts"]) and map_size(node["verdicts"]) > 0,
      "node #{inspect(node["id"])}: a verifier node needs non-empty verdicts"
    )
    |> check(
      uppercase_verdicts(node),
      &"node #{inspect(node["id"])}: verdict #{inspect(&1)} must be lowercase - Prompt.verdict/2 lowercases the reply before matching"
    )
    |> check_bool(is_nil(node["next"]), "node #{inspect(node["id"])}: a verifier node cannot have next (use verdicts)")
  end

  defp validate_node_type(errors, %{"type" => "human"} = node, _owner) do
    errors
    |> check_bool(is_binary(node["ask"]) and node["ask"] != "", "node #{inspect(node["id"])}: a human node needs an \"ask\"")
    |> check_bool(is_nil(node["verdicts"]), "node #{inspect(node["id"])}: a human node cannot have verdicts")
  end

  # Same reason as the `tool` node check below: nothing on this path otherwise checks the
  # executing agent's tools allowlist before fanning out via `delegate` - a graph would
  # let an agent that was never given `delegate` reach it anyway just by using this node
  # type. `Runner.run_node/4`'s `parallel` clause also gates this call live, the same way
  # the `tool` node type already does, rather than calling `Tools.execute/2` unguarded.
  defp validate_node_type(errors, %{"type" => "parallel"} = node, _owner) do
    resolved = is_binary(node["agent"]) && Config.get_agent(node["agent"])

    errors
    |> check_bool(
      is_list(node["tasks"]) and node["tasks"] != [],
      "node #{inspect(node["id"])}: a parallel node needs a non-empty tasks list"
    )
    |> check_bool(
      not is_list(node["tasks"]) or Enum.all?(node["tasks"], &is_binary/1),
      "node #{inspect(node["id"])}: every task must be a string"
    )
    |> check_bool(is_binary(node["agent"]) and not is_nil(resolved), "node #{inspect(node["id"])}: parallel needs a known agent")
    |> check_bool(
      !resolved or "delegate" in (resolved.tools || []),
      "node #{inspect(node["id"])}: #{node["agent"]} is not allowed to use delegate (not in its tools)"
    )
  end

  # A "tool" node calls `node["tool"]` directly - unlike "agent"/"verifier" (where the MODEL
  # picks from `Tools.specs(agent.tools)`, so it can never pick a tool the agent wasn't given)
  # or "parallel" (where `delegate` re-derives the target agent's own `.tools` itself), nothing
  # else on this path ever checks the executing agent's tools allowlist - `Permissions.gate/3`
  # and `Tools.execute/2` authorize a call by risk, not by whether the tool was ever granted to
  # this agent. Without this check, a graph would let an agent scoped down to a handful of safe
  # tools reach any other registered tool just by naming it in a node.
  defp validate_node_type(errors, %{"type" => "tool"} = node, owner) do
    tool = node["tool"]
    known_tool? = is_binary(tool) and not is_nil(Tools.get(tool))
    effective_agent = Config.get_agent(node["agent"] || owner.name)

    errors
    |> check_bool(tool not in @denied_tools, "node #{inspect(node["id"])}: use the #{tool} node type, not a tool node, for #{tool}")
    |> check_bool(known_tool?, "node #{inspect(node["id"])}: unknown tool #{inspect(tool)}")
    |> check_bool(
      not known_tool? or is_nil(effective_agent) or tool in (effective_agent.tools || []),
      "node #{inspect(node["id"])}: #{effective_agent && effective_agent.name} is not allowed to use #{inspect(tool)} (not in its tools)"
    )
    |> check_bool(is_nil(node["args"]) or is_map(node["args"]), "node #{inspect(node["id"])}: args must be a JSON object")
  end

  defp validate_node_type(errors, node, _owner), do: ["node #{inspect(node["id"])}: unknown type #{inspect(node["type"])}" | errors]

  defp uppercase_verdicts(%{"verdicts" => verdicts}) when is_map(verdicts) do
    verdicts |> Map.keys() |> Enum.reject(&(&1 == String.downcase(&1)))
  end

  defp uppercase_verdicts(_node), do: []

  defp dangling_targets(%{"type" => "verifier", "verdicts" => verdicts}, ids) when is_map(verdicts) do
    verdicts |> Map.values() |> Enum.reject(&(&1 == "end" or &1 in ids))
  end

  defp dangling_targets(%{"next" => next}, ids) when is_binary(next) do
    if next == "end" or next in ids, do: [], else: [next]
  end

  defp dangling_targets(_node, _ids), do: []

  defp unbound_template_refs(node, ids) do
    arg_values = node["args"] |> as_map() |> Map.values() |> Enum.filter(&is_binary/1)
    templates = [node["prompt"], node["ask"]] ++ List.wrap(node["tasks"]) ++ arg_values

    templates
    |> Enum.flat_map(&Prompt.referenced_keys/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ids))
  end

  defp duplicate_ids(ids), do: ids -- Enum.uniq(ids)
  defp reserved_ids(ids), do: Enum.filter(ids, &(&1 in @reserved_ids))
  defp invalid_id_shapes(ids), do: Enum.reject(ids, &(is_binary(&1) and Regex.match?(@id_pattern, &1)))

  defp as_map(m) when is_map(m), do: m
  defp as_map(_not_a_map), do: %{}

  defp check(errors, [], _fmt), do: errors
  defp check(errors, problems, fmt), do: Enum.map(problems, fmt) ++ errors

  defp check_bool(errors, true, _message), do: errors
  defp check_bool(errors, false, message), do: [message | errors]

  ###
  ### helpers
  ###

  defp canonical_agent(agent_ref) do
    case Config.get_agent(agent_ref) do
      nil -> nil
      agent -> agent.name
    end
  end

  defp clamp_max_steps(nil), do: 25
  defp clamp_max_steps(n) when is_integer(n), do: n |> max(@max_steps_range.first) |> min(@max_steps_range.last)
  defp clamp_max_steps(_), do: 25

  defp new_id, do: "graph_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  defp map_or_nil(record, mapper \\ &to_map/1)
  defp map_or_nil(nil, _mapper), do: nil
  defp map_or_nil(record, mapper), do: mapper.(record)

  defp to_map(%Definition{} = d) do
    %{
      "id" => d.id,
      "name" => d.name,
      "agent" => d.agent,
      "entry" => d.entry,
      "nodes" => d.nodes,
      "state" => d.state,
      "max_steps" => d.max_steps,
      "created_at" => d.created_at,
      "updated_at" => d.updated_at
    }
  end

  defp run_to_map(%Run{} = r) do
    %{
      "id" => r.id,
      "graph_id" => r.graph_id,
      "agent" => r.agent,
      "graph_name" => r.graph_name,
      "input" => r.input,
      "state" => r.state,
      "history" => r.history,
      "current_node" => r.current_node,
      "visits" => r.visits,
      "steps_taken" => r.steps_taken,
      "max_steps" => r.max_steps,
      "tainted_keys" => r.tainted_keys,
      "tainted_from_start" => r.tainted_from_start,
      "status" => r.status,
      "error" => r.error,
      "session_key" => r.session_key,
      "origin" => r.origin,
      "created_at" => r.created_at,
      "updated_at" => r.updated_at,
      "finished_at" => r.finished_at
    }
  end
end
