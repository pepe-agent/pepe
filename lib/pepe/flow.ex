defmodule Pepe.Flow do
  @moduledoc """
  A proven sequence of tool calls, promoted from real traces, that replays without ever
  calling the model - the "notice this worked the same way three times, stop re-deciding
  it from scratch" idea (from a competing framework's own community: agents that re-plan
  every turn instead of learning which flows are reliable and turning them into scripts).

  Deliberately the smallest safe version, not a script-generation engine:

    * **Promotion is a human decision, not automatic detection.** `promote_from_traces/4`
      takes trace ids the operator already looked at (via `mix pepe traces`) and picked
      themselves - there is no background job guessing "this looks like a pattern." The
      review r/openclaw's own thread wanted (a human confirms this is really the same
      reliable flow) already happens at the moment the operator runs the command, so
      there's no separate approval queue to build on top of it.
    * **No templating, no parameterized inputs.** A flow replays the *exact* tool calls
      it was promoted from, argument for argument. Auto-inferring "this part varies,
      that part doesn't" from a handful of examples is the riskiest part of this whole
      idea - guess wrong and a flow silently does something the traces it came from
      never did. `promote_from_traces/4` refuses outright if the given traces aren't
      already carrying the identical tool-call sequence; parameterized flows are a
      real, separate feature for later, not a first cut.
    * **Runs with nobody watching, so it only runs what was already pre-approved.** A
      flow triggers from a cron, not a chat - there is no human on the line to ask, so
      it goes through `Pepe.Permissions.gate/3` exactly the way any other unattended
      surface does (a webhook, an API token): only a step whose tool is in the agent's
      own `auto_approve` runs; anything else refuses the whole flow rather than skip a
      step silently. This is the same boundary this codebase already trusts everywhere
      else nobody is watching - not a new one invented for flows.

  Backed by `Pepe.Repo` (SQLite), matching every other operational subsystem here. Every
  public function takes/returns bare string-keyed maps, not the `Pepe.Flow.Flow` schema -
  same boundary `Pepe.Trace` already draws.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config
  alias Pepe.Flow.Flow
  alias Pepe.Permissions
  alias Pepe.Repo
  alias Pepe.Tools
  alias Pepe.Trace

  @doc "Every flow for one agent (a bare handle resolves the same as a full one), sorted by name."
  @spec for_agent(String.t()) :: [map()]
  def for_agent(agent_ref) do
    case canonical_agent(agent_ref) do
      nil -> []
      agent -> from(f in Flow, where: f.agent == ^agent, order_by: f.name) |> Repo.all() |> Enum.map(&to_map/1)
    end
  end

  @doc """
  Fetch one flow by agent + name, or `nil`. `agent_ref` resolves the same way any other
  agent reference does (a bare handle like "assistant", not just the stored full one) -
  a flow is always stored under its promoting agent's canonical handle (see
  `promote_from_traces/4`), so a lookup has to match that, not whatever shorthand the
  caller happened to type.
  """
  @spec get(String.t(), String.t()) :: map() | nil
  def get(agent_ref, name) do
    case canonical_agent(agent_ref) do
      nil ->
        nil

      agent ->
        case Repo.get_by(Flow, agent: agent, name: name) do
          nil -> nil
          entry -> to_map(entry)
        end
    end
  end

  defp canonical_agent(agent_ref) do
    case Config.get_agent(agent_ref) do
      nil -> nil
      agent -> agent.name
    end
  end

  @doc """
  Promote `trace_ids` (at least 2, all belonging to `agent`) into a named, replayable
  flow - refusing unless every one of them made the *exact* same ordered sequence of
  tool calls (same tool, same arguments). That equality check is the whole "is this
  really the same reliable flow" judgment; a human already made it by picking these
  specific traces to promote.
  """
  @spec promote_from_traces(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def promote_from_traces(name, agent, trace_ids, opts \\ [])

  def promote_from_traces(name, agent_ref, trace_ids, opts) when length(trace_ids) >= 2 do
    traces = Enum.map(trace_ids, &find_trace/1)
    # Canonicalized once, up front: a Cron's own `agent` field round-trips through the
    # same resolution (Config.resolve_cron_agent/1), so a "flow" cron built from a bare
    # handle must find this flow under the exact same full handle it will be looked up
    # with at run time - not whatever shorthand the operator happened to type.
    agent = Config.get_agent(agent_ref)

    cond do
      Enum.any?(traces, &is_nil/1) ->
        {:error, :trace_not_found}

      is_nil(agent) ->
        {:error, :unknown_agent}

      not is_nil(get(agent.name, name)) and opts[:overwrite] != true ->
        {:error, :already_exists}

      true ->
        case traces |> Enum.map(&tool_call_steps/1) |> Enum.uniq() do
          [[]] ->
            {:error, :no_tool_calls}

          [steps] ->
            create(name, agent.name, steps, trace_ids)

          _ ->
            {:error, :traces_dont_match}
        end
    end
  end

  def promote_from_traces(_name, _agent, _trace_ids, _opts), do: {:error, :need_at_least_two_traces}

  # A trace id alone doesn't say which project scoped it - the same lookup
  # Mix.Tasks.Pepe.find_trace/2 already does for `mix pepe traces ID`.
  defp find_trace(id), do: Enum.find_value(Trace.scopes(), fn s -> Trace.get(s, id) end)

  defp create(name, agent, steps, trace_ids) do
    id = new_id()
    now = System.system_time(:second)
    row = %{id: id, name: name, agent: agent, steps: steps, source_trace_ids: trace_ids, created_at: now}

    Repo.insert_all(Flow, [row], on_conflict: {:replace, [:steps, :source_trace_ids, :created_at]}, conflict_target: [:agent, :name])
    {:ok, get(agent, name)}
  end

  @doc "Delete a flow by agent + name."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(agent_ref, name) do
    case canonical_agent(agent_ref) do
      nil -> :ok
      agent -> from(f in Flow, where: f.agent == ^agent and f.name == ^name) |> Repo.delete_all() |> then(fn _ -> :ok end)
    end
  end

  @doc """
  Replay a flow's steps, in order, calling no model at all. Stops at the first step that
  fails or is not pre-approved (the agent's `auto_approve` - there is nobody here to ask),
  rather than skip it and carry on with a partial run. Every step still goes through
  `Pepe.Tools.execute/2`, so a step's own write/side effect happens exactly the way it
  would from a real turn. Records its own trace (`source: "flow"`) for the same audit
  trail a normal run gets.
  """
  @spec run(map()) :: {:ok, [String.t()]} | {:error, term()}
  def run(%{"agent" => agent_name, "steps" => steps} = flow) do
    case Config.get_agent(agent_name) do
      nil ->
        {:error, :unknown_agent}

      agent ->
        # Matches Pepe.Agent.Runtime.run/3's own pattern: only the outermost caller owns
        # (and finishes) the trace - a flow triggered from inside an already-running turn
        # (e.g. a tool that fires one) folds into that turn's trace instead of ending it early.
        own_trace? = Trace.start(agent_name, nil, "flow: #{flow["name"]}", "flow") == :started
        ctx = %{agent: agent, cwd: File.cwd!()}
        result = replay(steps, ctx)
        record_result(flow, result)
        if own_trace?, do: Trace.finish(to_outcome(result))
        result
    end
  end

  defp replay(steps, ctx) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      name = step["tool"]
      args = step["args"]

      case Permissions.gate(name, args, ctx) do
        :allow ->
          call = %{"function" => %{"name" => name, "arguments" => args}}
          out = Tools.execute(call, ctx)
          Trace.event({:tool_call, name, args})
          Trace.event({:tool_result, name, out})
          {:cont, {:ok, [out | acc]}}

        :deny ->
          {:halt, {:error, {:denied, name}}}

        {:deny, reason} ->
          {:halt, {:error, {:denied, name, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp to_outcome({:ok, _}), do: {:ok, "flow completed", []}
  defp to_outcome({:error, reason}), do: {:error, reason}

  defp record_result(flow, result) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error: #{inspect(elem(result, 1))}"

    from(f in Flow, where: f.agent == ^flow["agent"] and f.name == ^flow["name"])
    |> Repo.update_all(set: [last_run: System.system_time(:second), last_result: outcome])
  end

  # A flow's own identity: same tool, same arguments, in order. Nothing else about a
  # trace (timing, the final reply, token usage) matters for "is this the same flow" -
  # see the moduledoc for why this stays a strict equality check, not a fuzzy one.
  defp tool_call_steps(trace) do
    trace["events"]
    |> Enum.filter(&(&1["t"] == "tool_call"))
    |> Enum.map(&%{"tool" => &1["name"], "args" => &1["args"]})
  end

  defp to_map(%Flow{} = e) do
    %{
      "id" => e.id,
      "name" => e.name,
      "agent" => e.agent,
      "steps" => e.steps,
      "source_trace_ids" => e.source_trace_ids,
      "created_at" => e.created_at,
      "last_run" => e.last_run,
      "last_result" => e.last_result
    }
  end

  defp new_id, do: "flow_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
end
