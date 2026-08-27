defmodule Pepe.Graph.Runner do
  @moduledoc """
  The execution loop `Pepe.Graph.run/4` and `Pepe.Graph.resume/2` delegate to.
  Synchronous, in the calling process - same as `Pepe.Flow.run/1`, no `Task` spawned for
  the whole run. Each node is a completely fresh call (`Pepe.Agent.Runtime.converse/3`
  for `agent`/`verifier`, `Pepe.Tools.execute/2` for `parallel`/`tool`) with no message
  history carried over - `state` is the only channel between nodes, so a graph node adds
  no permission surface of its own: it's still the real gate doing the gating.

  Taint is tracked per `state` key (`Run.tainted_keys`), not as one run-wide flag: a
  node's call is only born untrusted (`untrusted: true`) if its own prompt/args actually
  reference a tainted key (`Pepe.Graph.Prompt.referenced_keys/1`), and if that call
  itself ends up tainted, its own output key joins `tainted_keys` for whoever reads it
  next. This never under-taints (a node can't read a tainted key without inheriting the
  taint) and never over-taints a node that only touches clean state - the one exception
  being `Run.tainted_from_start`: a `run_graph` call made from an already-tainted
  conversation seeds every node in the new run untrusted, deliberately, so a graph can't
  be used to launder a tainted turn clean just by starting a fresh one (mirrors
  `delegate`'s own `untrusted: Permissions.tainted?(ctx)` forwarding).

  A `human` node is the one case where the loop does not continue by itself: it persists
  `status: "waiting_human"` and returns. `resume/2` is event-driven (like
  `Pepe.Permissions.PendingApprovals`, not `Pepe.Commitments.Scheduler`'s time-poll) -
  a human answers whenever they answer, resolved with the same atomic
  compare-and-swap discipline (`claim/3`) `PendingApprovals.claim/3` uses, so N
  concurrent resume attempts on the same run have exactly one winner.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Graph.Prompt
  alias Pepe.Graph.Run
  alias Pepe.Permissions
  alias Pepe.Repo
  alias Pepe.Tools
  alias Pepe.Watch.Delivery

  import Ecto.Query, only: [from: 2]

  @doc """
  Start a run from an already-validated, frozen `definition` map (see
  `Pepe.Graph.import/2`). `opts[:session_key]` + `opts[:origin]` (the same pair
  `Pepe.Permissions.PendingApproval` stores) are set when this run was started by
  `run_graph` from inside a live conversation, so a later `resume/2` can hand the
  eventual result back into it; `opts[:on_event]` passes through to every
  `Runtime.converse/3` call.
  """
  @spec start(map(), String.t() | nil, keyword()) :: map()
  def start(definition, input, opts \\ []) do
    now = now()

    run = %Run{
      id: new_id(),
      graph_id: definition["id"],
      agent: definition["agent"],
      graph_name: definition["name"],
      definition: definition,
      input: input,
      state: definition["state"] || %{},
      history: [],
      current_node: definition["entry"],
      visits: %{},
      steps_taken: 0,
      max_steps: definition["max_steps"] || 25,
      tainted_keys: [],
      # `run_graph`, called from an already-tainted conversation, must not launder that
      # taint away just by starting a fresh run: every node here starts untrusted
      # regardless of which keys it reads - the same over-taint `delegate`'s own
      # `untrusted: Permissions.tainted?(ctx)` forwarding already accepts.
      tainted_from_start: opts[:untrusted] == true,
      status: "running",
      session_key: opts[:session_key],
      origin: opts[:origin] || %{},
      created_at: now,
      updated_at: now
    }

    {:ok, run} = Repo.insert(Run.changeset(run, %{}))
    run |> loop(opts, false) |> to_map()
  end

  @doc """
  Resume a `waiting_human` run with the human's raw text reply. `{:error, {:already,
  status}}` when the run isn't (or is no longer) waiting; `{:error, :not_found}` when
  the id doesn't exist.
  """
  @spec resume(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | {:already, String.t()}}
  def resume(run_id, human_reply) do
    with {:ok, run} <- claim(run_id, "waiting_human", "running") do
      node = fetch_node!(run, run.current_node)

      run
      |> apply_step(node["id"], human_reply, node["next"] || "end", false)
      |> continue(node["next"] || "end", [], true)
      |> to_map()
      |> then(&{:ok, &1})
    end
  end

  ###
  ### the loop
  ###

  defp loop(%Run{status: "running"} = run, opts, resumed?) do
    if run.steps_taken >= run.max_steps do
      finish(run, "failed", cap_error(run), opts, resumed?)
    else
      node = fetch_node!(run, run.current_node)
      run |> pre_step() |> run_node(node, opts, resumed?)
    end
  end

  defp loop(%Run{} = run, _opts, _resumed?), do: run

  defp run_node(run, %{"type" => "human"} = node, opts, resumed?) do
    case Prompt.render(node["ask"], run.state, run.input) do
      {:ok, ask} ->
        run
        |> Map.put(:status, "waiting_human")
        |> open_history(node["id"], ask)
        |> persist!()

      {:error, {:unbound_ref, key}} ->
        finish(run, "failed", unbound_error(node, key), opts, resumed?)
    end
  end

  defp run_node(run, %{"type" => type} = node, opts, resumed?) when type in ["agent", "verifier"] do
    with {:ok, prompt} <- Prompt.render(node["prompt"], run.state, run.input),
         %{} = node_agent <- resolve_agent(node, run) do
      node_tainted? = node_tainted?(run, node["prompt"])

      case Runtime.converse(node_agent, prompt,
             source: "graph",
             untrusted: node_tainted?,
             on_event: opts[:on_event],
             # So `run_graph`, called mid-turn by this node's own model, can refuse to
             # run itself - see `Pepe.Tools.RunGraph`'s recursion guard.
             graph_run_id: run.id
           ) do
        {:ok, reply, _messages} -> apply_reply(run, type, node, reply, opts, resumed?)
        {:error, reason} -> finish(run, "failed", "node #{node["id"]}: #{inspect(reason)}", opts, resumed?)
      end
    else
      {:error, {:unbound_ref, key}} -> finish(run, "failed", unbound_error(node, key), opts, resumed?)
      nil -> finish(run, "failed", unavailable_agent_error(node, run), opts, resumed?)
    end
  end

  defp run_node(run, %{"type" => "parallel"} = node, opts, resumed?) do
    with {:ok, tasks} <- render_list(node["tasks"] || [], run.state, run.input),
         %{} = node_agent <- resolve_agent(node, run) do
      node_tainted? = node_tainted?(run, Enum.join(node["tasks"] || [], "\n"))
      cwd = Workspace.cwd_in_ctx(%{agent: node_agent})
      ctx = %{agent: node_agent, cwd: cwd, untrusted: node_tainted?, source: "graph", graph_run_id: run.id}
      call = %{"function" => %{"name" => "delegate", "arguments" => %{"tasks" => tasks}}}

      {result, became_tainted?} =
        with_taint_seed(node_tainted?, fn ->
          result = Tools.execute(call, ctx)
          # `delegate` is always in `Runtime.outside_content?/1`'s list (sub-agent workers may
          # have read arbitrary web/file content) - but calling `Tools.execute/2` directly here
          # skips Runtime's own turn loop, whose `finalize_tool/3` is the only place that
          # normally marks this. Without it, a parallel node's own output key would never join
          # `tainted_keys`, and a downstream node reading it would run trusted by mistake.
          Runtime.taint_if_outside("delegate")
          {result, elem(Permissions.snapshot(), 0)}
        end)

      next = node["next"] || "end"
      run |> apply_step(node["id"], result, next, became_tainted?) |> continue(next, opts, resumed?)
    else
      {:error, {:unbound_ref, key}} -> finish(run, "failed", unbound_error(node, key), opts, resumed?)
      nil -> finish(run, "failed", unavailable_agent_error(node, run), opts, resumed?)
    end
  end

  defp run_node(run, %{"type" => "tool"} = node, opts, resumed?) do
    with {:ok, args} <- render_map(node["args"] || %{}, run.state, run.input),
         %{} = node_agent <- resolve_tool_agent(node, run) do
      node_tainted? = node_tainted?(run, Jason.encode!(node["args"] || %{}))
      cwd = Workspace.cwd_in_ctx(%{agent: node_agent})
      ctx = %{agent: node_agent, cwd: cwd, untrusted: node_tainted?, source: "graph", graph_run_id: run.id}

      outcome = with_taint_seed(node_tainted?, fn -> run_gated_tool(node, args, ctx) end)
      apply_tool_outcome(run, node, outcome, opts, resumed?)
    else
      {:error, {:unbound_ref, key}} -> finish(run, "failed", unbound_error(node, key), opts, resumed?)
      nil -> finish(run, "failed", unavailable_agent_error(node, run), opts, resumed?)
    end
  end

  # `Tools.execute/2` (for `parallel`/`tool` nodes) doesn't reset/seed taint the way
  # `Runtime.converse/3` does internally for `agent`/`verifier` nodes - a delegate worker
  # or a gated tool call reads the *current* process taint directly. Snapshot/restore
  # around the call, same technique `PendingApprovals.run_stored_call/2` uses to replay a
  # tainted approval: seed it in if this node is tainted, read what it ended as, then
  # restore so it never leaks into whatever runs next in this same process.
  #
  # `fun` must return its result WITHOUT recursing into the rest of the graph (no
  # `apply_step`/`continue` inside it) - `continue/4` recurses synchronously into the next
  # node in this same process, and `after` here only fires once that whole recursion
  # finally unwinds, so a `fun` that kept going itself would hold this node's taint live
  # for every node downstream instead of just for this one call.
  defp with_taint_seed(node_tainted?, fun) do
    saved = Permissions.snapshot()
    if node_tainted?, do: Permissions.taint()

    try do
      fun.()
    after
      Permissions.restore(saved)
    end
  end

  defp apply_tool_outcome(run, node, {:ok, result, became_tainted?}, opts, resumed?) do
    next = node["next"] || "end"
    run |> apply_step(node["id"], result, next, became_tainted?) |> continue(next, opts, resumed?)
  end

  defp apply_tool_outcome(run, node, {:error, message}, opts, resumed?) do
    finish(run, "failed", "node #{node["id"]}: #{message}", opts, resumed?)
  end

  defp run_gated_tool(node, args, ctx) do
    case Permissions.gate(node["tool"], args, ctx) do
      :allow ->
        call = %{"function" => %{"name" => node["tool"], "arguments" => args}}
        result = Tools.execute(call, ctx)
        # Same reason as the `parallel` clause above: `Tools.execute/2` bypasses Runtime's
        # loop, so a call to an outside-content tool (fetch_url, web_search, an MCP tool...)
        # would otherwise never mark this node's output key tainted.
        Runtime.taint_if_outside(node["tool"])
        {:ok, result, elem(Permissions.snapshot(), 0)}

      :deny ->
        {:error, "#{node["tool"]} was not authorized"}

      {:deny, reason} ->
        {:error, "#{node["tool"]} was not authorized (#{reason})"}
    end
  end

  defp apply_reply(run, type, node, reply, opts, resumed?) do
    became_tainted? = elem(Permissions.snapshot(), 0)

    case node_next(type, node, reply) do
      {:ok, next_id, verdict} ->
        run |> apply_step(node["id"], reply, next_id, became_tainted?, verdict) |> continue(next_id, opts, resumed?)

      {:error, {:bad_verdict, last_line}} ->
        finish(run, "failed", bad_verdict_error(node, last_line), opts, resumed?)
    end
  end

  defp node_next("agent", node, _reply), do: {:ok, node["next"] || "end", nil}

  defp node_next("verifier", node, reply) do
    case Prompt.verdict(reply, node["verdicts"]) do
      {:ok, verdict, target} -> {:ok, target, verdict}
      error -> error
    end
  end

  defp continue(run, "end", opts, resumed?), do: finish(run, "done", nil, opts, resumed?)
  defp continue(run, next_id, opts, resumed?), do: loop(%{run | current_node: next_id}, opts, resumed?)

  ###
  ### state / taint / history bookkeeping
  ###

  defp pre_step(run) do
    visits = Map.update(run.visits, run.current_node, 1, &(&1 + 1))

    %{run | visits: visits, steps_taken: run.steps_taken + 1, updated_at: now()}
    |> persist!()
  end

  defp node_tainted?(run, template_or_text) do
    run.tainted_from_start or
      template_or_text
      |> Prompt.referenced_keys()
      |> Enum.any?(&(&1 in run.tainted_keys))
  end

  defp apply_step(run, node_id, output, next_id, became_tainted?, verdict \\ nil) do
    tainted_keys = if became_tainted?, do: Enum.uniq([node_id | run.tainted_keys]), else: run.tainted_keys

    run
    |> Map.put(:state, Map.put(run.state, node_id, output))
    |> Map.put(:tainted_keys, tainted_keys)
    |> close_history(node_id, output, next_id, became_tainted?, verdict)
    |> Map.put(:updated_at, now())
    |> persist!()
  end

  defp open_history(run, node_id, asked) do
    entry = %{
      "node" => node_id,
      "visit" => Map.get(run.visits, node_id, 1),
      "started_at" => now(),
      "asked" => clip(asked)
    }

    %{run | history: run.history ++ [entry]}
  end

  defp close_history(run, node_id, output, next_id, tainted?, verdict) do
    fields = %{"reply" => clip(output), "next" => next_id, "verdict" => verdict, "tainted" => tainted?, "finished_at" => now()}

    history =
      case Enum.split(run.history, -1) do
        {rest, [%{"node" => ^node_id} = last]} ->
          rest ++ [Map.merge(last, fields)]

        _ ->
          run.history ++
            [Map.merge(%{"node" => node_id, "visit" => Map.get(run.visits, node_id, 1), "started_at" => now()}, fields)]
      end

    %{run | history: history}
  end

  @clip 2_000
  defp clip(nil), do: nil
  defp clip(text) when byte_size(text) > @clip, do: binary_part(text, 0, @clip) <> "... (clipped)"
  defp clip(text), do: text

  ###
  ### finishing, resuming, and hand-back
  ###

  defp finish(run, status, error, opts, resumed?) do
    now = now()
    run = %{run | status: status, error: error, finished_at: now, updated_at: now}

    from(r in Run, where: r.id == ^run.id and r.status in ["running", "waiting_human"])
    |> Repo.update_all(set: [status: status, error: error, finished_at: now, updated_at: now])

    if resumed?, do: hand_back(run, opts)
    run
  end

  defp persist!(run) do
    from(r in Run, where: r.id == ^run.id)
    |> Repo.update_all(
      set: [
        state: run.state,
        history: run.history,
        current_node: run.current_node,
        visits: run.visits,
        steps_taken: run.steps_taken,
        tainted_keys: run.tainted_keys,
        status: run.status,
        updated_at: run.updated_at
      ]
    )

    run
  end

  # Delivering the final result back into the session that started this run only makes
  # sense when finishing happens OUTSIDE the turn that started it - i.e. via `resume/2`,
  # which by definition runs later, in a separate CLI/tool invocation. A `run_graph` call
  # that finishes synchronously within its own turn never needs this: its return value
  # already IS the result. Same sequence `PendingApprovals.hand_back/3` uses.
  defp hand_back(%Run{session_key: key} = run, _opts) when is_binary(key) do
    note = hand_back_note(run)

    with {:ok, _pid} <- SessionSupervisor.ensure(key, run.agent),
         {:ok, reply} <- Session.chat(key, note, untrusted: run.tainted_keys != []) do
      Delivery.deliver(run.origin, reply)
      :ok
    else
      _ -> :ok
    end
  end

  defp hand_back(_run, _opts), do: :ok

  defp hand_back_note(%Run{status: "done"} = run) do
    "[Graph update - the user does not see this note, only the reply you send now.]\n" <>
      "Graph \"#{run.graph_name}\" (run #{run.id}) finished. Final state at node " <>
      "#{run.current_node}: #{clip(Map.get(run.state, run.current_node, ""))}"
  end

  defp hand_back_note(%Run{} = run) do
    "[Graph update - the user does not see this note, only the reply you send now.]\n" <>
      "Graph \"#{run.graph_name}\" (run #{run.id}) failed: #{run.error}"
  end

  # Atomic compare-and-swap, same discipline as `PendingApprovals.claim/3` - N concurrent
  # callers racing to resume the same run get exactly one winner.
  defp claim(run_id, from_status, to_status) do
    case Repo.get(Run, run_id) do
      nil ->
        {:error, :not_found}

      %Run{status: ^from_status} ->
        {count, _} =
          from(r in Run, where: r.id == ^run_id and r.status == ^from_status)
          |> Repo.update_all(set: [status: to_status, updated_at: now()])

        if count == 1 do
          {:ok, %{Repo.get!(Run, run_id) | status: to_status}}
        else
          {:error, {:already, current_status(run_id)}}
        end

      %Run{status: other} ->
        {:error, {:already, other}}
    end
  end

  defp current_status(run_id), do: Repo.get(Run, run_id) |> Map.get(:status, "unknown")

  ###
  ### helpers
  ###

  # Re-checked live, not just at `Pepe.Graph.import/2` time: the owning agent's
  # `can_message` (or, for a `tool` node, its `tools`) can be revoked after a graph was
  # saved, and a stale saved definition must not keep running as if nothing changed -
  # the same TOCTOU a permission check anywhere else in Pepe is expected to close.
  defp resolve_agent(node, run) do
    with %{} = agent <- Config.get_agent(node["agent"] || run.agent),
         true <- authorized_node_agent?(run, agent) do
      agent
    else
      _ -> nil
    end
  end

  defp resolve_tool_agent(node, run) do
    with %{} = agent <- resolve_agent(node, run),
         true <- node["tool"] in (agent.tools || []) do
      agent
    else
      _ -> nil
    end
  end

  defp authorized_node_agent?(run, agent) do
    agent.name == run.agent or agent.name in (owner_can_message(run) || [])
  end

  defp owner_can_message(run) do
    case Config.get_agent(run.agent) do
      nil -> []
      owner -> owner.can_message
    end
  end

  defp unavailable_agent_error(node, run) do
    "node #{node["id"]}: #{inspect(node["agent"] || run.agent)} is not available to run this node " <>
      "(unknown, not authorized, or no longer has the tool this node needs)"
  end

  defp fetch_node!(run, node_id) do
    Enum.find(run.definition["nodes"] || [], &(&1["id"] == node_id)) ||
      raise "Pepe.Graph.Runner: node #{inspect(node_id)} missing from a frozen definition - this should have been caught at save time"
  end

  defp render_list(list, state, input) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case Prompt.render(item, state, input) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp render_map(map, state, input) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(value) ->
        case Prompt.render(value, state, input) do
          {:ok, rendered} -> {:cont, {:ok, Map.put(acc, key, rendered)}}
          error -> {:halt, error}
        end

      {key, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, key, value)}}
    end)
  end

  defp cap_error(run),
    do:
      "step budget exhausted (#{run.max_steps} steps) at node #{run.current_node} - " <>
        "likely a verifier reject-loop; raise max_steps or fix the loop"

  defp unbound_error(node, key), do: "node #{node["id"]}: unbound reference {{#{key}}}"

  defp bad_verdict_error(node, last_line),
    do: "node #{node["id"]}: reply's last line #{inspect(last_line)} matches no verdict"

  defp new_id, do: "grun_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

  defp now, do: System.system_time(:second)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp to_map(%Run{} = run) do
    run
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> stringify()
  end
end
