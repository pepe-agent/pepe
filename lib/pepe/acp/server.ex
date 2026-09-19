defmodule Pepe.ACP.Server do
  @moduledoc """
  One Agent Client Protocol connection: the editor on one side, `Pepe.Agent` on the other.

  This is a translation layer, not a second agent loop. An ACP session *is* a
  `Pepe.Agent.Session` (keyed `acp:<id>`, so it gets the same context retention, the
  same `/stop`, the same session-scoped permission grants every other surface has); an
  ACP prompt turn *is* one `Pepe.Agent.chat/4`; and the `session/update` notifications
  an editor renders are `Pepe.Agent.Runtime`'s own lifecycle events, re-encoded.
  Nothing here decides anything the rest of Pepe wouldn't have decided on its own.

  ## Why this is a process, and not a loop

  Two things have to happen at once during a prompt turn. The agent is working, and
  the editor may speak at any moment - to cancel, or to answer a permission request
  the agent itself just asked for. So the turn runs in its own task and this
  GenServer stays free to read:

    * the task calls `Pepe.Agent.chat/4` and casts `{:prompt_done, ...}` back;
    * `:on_event` casts each runtime event here, to go out as `session/update`;
    * `:authorize` **calls** here and blocks. This server sends
      `session/request_permission`, parks the caller's `from` without replying, and
      answers it only when the editor's response arrives on stdin.

  That last one is the whole point of the design: a human's answer travels back into
  `Pepe.Permissions.gate/3` as an ordinary decision, through the exact callback
  contract Telegram's inline buttons and the CLI's arrow-key menu already use. There
  is no parallel approval path here, and no way for a call to be quietly allowed or
  quietly refused - the editor either answers, or the turn is cancelled.

  ## Transport-free on purpose

  It never touches stdin or stdout. Messages arrive through `handle_line/2` and leave
  through the `:writer` function given at start. `Pepe.ACP.Stdio` supplies the real
  pipe; a test supplies a function that sends to the test process, which is how the
  handshake, a prompt turn and a permission round trip can all be exercised over real
  JSON without a subprocess.

  See `Pepe.ACP.Protocol` for which parts of the protocol are implemented and which
  are deliberately reported as unsupported.
  """

  use GenServer

  require Logger

  alias Pepe.ACP.Protocol
  alias Pepe.Agent.Session
  alias Pepe.Permissions.Prompt

  defstruct writer: nil,
            agent: nil,
            initialized?: false,
            sessions: %{},
            pending: %{},
            next_id: 1,
            next_session: 1

  @type t :: %__MODULE__{}

  ###
  ### client API
  ###

  @doc """
  Start a connection. `:writer` is a 1-arity function taking one encoded JSON-RPC
  message (a binary, no trailing newline); `:agent` is the configured agent name this
  connection talks to, or `nil` for the default one.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Feed one inbound line (one JSON-RPC message) to the connection."
  @spec handle_line(GenServer.server(), binary()) :: :ok
  def handle_line(server, line), do: GenServer.cast(server, {:line, line})

  ###
  ### server callbacks
  ###

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       writer: Keyword.fetch!(opts, :writer),
       agent: Keyword.get(opts, :agent)
     }}
  end

  @impl true
  def handle_cast({:line, line}, state) do
    case decode(line) do
      :skip -> {:noreply, state}
      {:ok, message} -> {:noreply, dispatch(message, state)}
      {:error, reason} -> {:noreply, write(state, Protocol.error(nil, Protocol.error_code(:parse), reason))}
    end
  end

  def handle_cast({:event, session_id, event}, state),
    do: {:noreply, on_event(event, session_id, state)}

  def handle_cast({:prompt_done, session_id, result}, state),
    do: {:noreply, finish_prompt(session_id, result, state)}

  @impl true
  # A synchronous marker behind everything already queued - `Pepe.ACP.Stdio` uses it at
  # EOF to be sure the last lines it read actually produced their replies before the VM
  # is allowed to exit.
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call({:authorize, session_id, name, args, ctx}, from, state) do
    case state.sessions[session_id] do
      # The session went away under a turn that was still running (only reachable if
      # the editor disconnected mid-call). Nobody can be asked, so nothing new runs.
      nil -> {:reply, :deny, state}
      session -> {:noreply, ask_permission(session_id, session, name, args, ctx, from, state)}
    end
  end

  ###
  ### inbound dispatch
  ###

  defp decode(line) do
    case String.trim(line) do
      "" ->
        :skip

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, message} when is_map(message) -> {:ok, message}
          {:ok, _other} -> {:error, "each line must be a single JSON-RPC object"}
          {:error, _} -> {:error, "line is not valid JSON"}
        end
    end
  end

  # A response to something we asked (only ever `session/request_permission`).
  defp dispatch(%{"id" => id} = message, state) when is_map_key(message, "result") or is_map_key(message, "error"),
    do: answer_permission(id, message, state)

  defp dispatch(%{"method" => method, "id" => id} = message, state),
    do: handle_request(method, id, params(message), state)

  defp dispatch(%{"method" => method} = message, state),
    do: handle_notification(method, params(message), state)

  defp dispatch(_other, state),
    do: write(state, Protocol.error(nil, Protocol.error_code(:invalid_request), "not a JSON-RPC request, notification or response"))

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_message), do: %{}

  ###
  ### requests
  ###

  defp handle_request("initialize", id, _params, state) do
    %{state | initialized?: true}
    |> write(Protocol.response(id, Protocol.initialize_result()))
  end

  defp handle_request(_method, id, _params, %{initialized?: false} = state),
    do: reply_error(state, id, :invalid_request, "`initialize` must be the first request on the connection")

  defp handle_request("session/new", id, params, state), do: new_session(id, params, state)
  defp handle_request("session/prompt", id, params, state), do: start_prompt(id, params, state)

  defp handle_request(method, id, _params, state),
    do:
      reply_error(
        state,
        id,
        :method_not_found,
        "this agent does not implement `#{method}` (see the capabilities it reported in `initialize`)"
      )

  ###
  ### notifications
  ###

  defp handle_notification("session/cancel", %{"sessionId" => session_id}, state),
    do: cancel(session_id, state)

  # Anything else is ignored on purpose: an unknown notification is not an error in
  # JSON-RPC, and there is nobody to tell.
  defp handle_notification(_method, _params, state), do: state

  ###
  ### session/new
  ###

  defp new_session(id, params, state) do
    cond do
      not is_binary(params["cwd"]) or not absolute?(params["cwd"]) ->
        reply_error(state, id, :invalid_params, "`cwd` is required and must be an absolute path")

      # Silently ignoring these would be the worse answer by far: the user configured
      # MCP servers in their editor, and would have no way to find out the agent never
      # connected to any of them. Pepe has its own MCP configuration
      # (`mix pepe mcp add`, stored per agent in ~/.pepe/config.json), which is what
      # actually reaches the model on every other surface too.
      params["mcpServers"] not in [nil, []] ->
        reply_error(
          state,
          id,
          :invalid_params,
          "this agent does not connect to client-supplied MCP servers; configure them on the agent itself with `pepe mcp add` and they apply on every surface"
        )

      true ->
        session_id = "sess_#{System.unique_integer([:positive, :monotonic])}"
        key = "acp:#{session_id}"

        session = %{key: key, cwd: params["cwd"], run: nil, tools: [], seq: 0}

        %{state | sessions: Map.put(state.sessions, session_id, session)}
        |> write(Protocol.response(id, %{"sessionId" => session_id}))
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute

  ###
  ### session/prompt
  ###

  defp start_prompt(id, params, state) do
    session_id = params["sessionId"]

    case state.sessions[session_id] do
      nil ->
        reply_error(state, id, :invalid_params, "unknown `sessionId` (create one with `session/new`)")

      %{run: run} when run != nil ->
        reply_error(state, id, :invalid_request, "this session already has a prompt turn in flight; cancel it first")

      session ->
        case Protocol.prompt_text(params["prompt"]) do
          {:ok, text} -> run_prompt(id, session_id, session, text, state)
          {:error, reason} -> reply_error(state, id, :invalid_params, reason)
        end
    end
  end

  defp run_prompt(id, session_id, session, text, state) do
    server = self()
    stream? = Pepe.Agent.stream_for?(state.agent)

    opts = [
      stream: stream?,
      # `cwd` is the directory the editor opened, and the one the agent's file and
      # shell tools should resolve against - an ACP path is always absolute, but the
      # workspace the model is told about has to match the project actually open.
      # `cwd_override` (not plain `cwd`) is what actually makes that happen: an ACP
      # session always has a real agent bound, and Pepe.Agent.Workspace resolves every
      # other bound-agent call inside that agent's own persistent workspace regardless
      # of `cwd` - only `cwd_override` outranks it (see that module's own doc).
      cwd: session.cwd,
      cwd_override: session.cwd,
      source: "acp",
      on_event: fn event -> GenServer.cast(server, {:event, session_id, event}) end,
      authorize: fn name, args, ctx ->
        GenServer.call(server, {:authorize, session_id, name, args, ctx}, :infinity)
      end
    ]

    {:ok, task} =
      Task.start(fn ->
        result = Pepe.Agent.chat(session.key, state.agent, text, opts)
        GenServer.cast(server, {:prompt_done, session_id, result})
      end)

    run = %{request_id: id, stream?: stream?, task: task}
    put_session(state, session_id, %{session | run: run, tools: []})
  end

  defp finish_prompt(session_id, result, state) do
    case state.sessions[session_id] do
      %{run: %{} = run} = session ->
        state = put_session(state, session_id, %{session | run: nil, tools: []})
        respond_to_prompt(session_id, run, result, state)

      # A turn that finished after its own cancellation already answered the request.
      _ ->
        state
    end
  end

  defp respond_to_prompt(session_id, run, {:ok, reply}, state) do
    # With streaming on, the editor already has this text as `agent_message_chunk`
    # deltas. Without it, the reply has to go out here, and going out here is also
    # what lets it be the *hook-processed* reply (PII restored) rather than the raw
    # model text a delta carries - the same split `mix pepe chat` makes.
    state =
      if run.stream? or reply in [nil, ""],
        do: state,
        else: write(state, Protocol.session_update(session_id, Protocol.message_chunk(reply)))

    write(state, Protocol.response(run.request_id, %{"stopReason" => "end_turn"}))
  end

  defp respond_to_prompt(_session_id, run, {:error, :stopped}, state),
    do: write(state, Protocol.response(run.request_id, %{"stopReason" => "cancelled"}))

  defp respond_to_prompt(_session_id, run, {:error, reason}, state),
    do: reply_error(state, run.request_id, :internal, "the agent run failed: #{inspect(reason)}")

  ###
  ### session/cancel
  ###

  defp cancel(session_id, state) do
    case state.sessions[session_id] do
      %{run: %{}} = session ->
        # The session kills the turn and answers its caller `{:error, :stopped}`,
        # which arrives here as `:prompt_done` and becomes stopReason "cancelled" -
        # the response ACP requires a cancelled turn to still produce. Any permission
        # request left hanging dies with the task that was blocked on it; the editor
        # is expected to answer those with a `cancelled` outcome, and an answer that
        # arrives for a `from` nobody is waiting on is simply dropped.
        Session.stop(session.key)
        drop_pending(session_id, state)

      _ ->
        state
    end
  end

  defp drop_pending(session_id, state) do
    pending = Map.reject(state.pending, fn {_id, {_from, sid}} -> sid == session_id end)
    %{state | pending: pending}
  end

  ###
  ### runtime events -> session/update
  ###

  defp on_event({:assistant_delta, text}, session_id, state) do
    case state.sessions[session_id] do
      %{run: %{stream?: true}} -> write(state, Protocol.session_update(session_id, Protocol.message_chunk(text)))
      _ -> state
    end
  end

  # A tool call is announced before the gate runs, so this is also what gives the call
  # the id a permission request will refer to. The runtime emits `:tool_call` for every
  # call in the order the model asked, and `:tool_result` for the same calls in that
  # same order, both from the run's own process - so a queue is enough to pair them,
  # with no id to thread through the event callback.
  defp on_event({:tool_call, name, raw_args}, session_id, state) do
    with_session(state, session_id, fn session ->
      id = "call_#{session.seq + 1}"
      entry = %{id: id, name: name, args: raw_args, denied: nil}
      session = %{session | seq: session.seq + 1, tools: session.tools ++ [entry]}

      {session, write(state, Protocol.session_update(session_id, Protocol.tool_call(id, name, raw_args)))}
    end)
  end

  # Always the call just announced: the runtime gates each call immediately after
  # emitting its `:tool_call`, so the denial belongs to the last one queued, never to
  # an earlier one that happens to share its name.
  defp on_event({:tool_denied, _name, reason}, session_id, state) do
    with_session(state, session_id, fn session ->
      case List.pop_at(session.tools, -1) do
        {nil, _rest} -> {session, state}
        {last, rest} -> {%{session | tools: rest ++ [%{last | denied: reason || true}]}, state}
      end
    end)
  end

  defp on_event({:tool_result, _name, output}, session_id, state) do
    with_session(state, session_id, &close_tool_call(&1, session_id, output, state))
  end

  # `:assistant` carries the same text the deltas already did (streaming) or text that
  # has yet to go through the agent's outbound hooks (not streaming, where the reply
  # goes out in `respond_to_prompt/4` instead). Either way it is not this event's job.
  defp on_event(_event, _session_id, state), do: state

  defp close_tool_call(%{tools: []} = session, _session_id, _output, state), do: {session, state}

  defp close_tool_call(%{tools: [entry | rest]} = session, session_id, output, state) do
    status = if entry.denied, do: "failed", else: "completed"
    update = Protocol.tool_call_update(entry.id, status, output)
    {%{session | tools: rest}, write(state, Protocol.session_update(session_id, update))}
  end

  defp with_session(state, session_id, fun) do
    case state.sessions[session_id] do
      nil ->
        state

      session ->
        {session, state} = fun.(session)
        put_session(state, session_id, session)
    end
  end

  ###
  ### permissions
  ###

  defp ask_permission(session_id, session, name, args, ctx, from, state) do
    tainted? = ctx[:tainted] == true
    decisions = Prompt.options(tainted?, is_binary(ctx[:session_key]))
    {rpc_id, state} = next_id(state)

    tool_call =
      Protocol.permission_tool_call(
        tool_call_id(session, name),
        name,
        args,
        notes(tainted?, ctx[:policy_reason], ctx[:risks])
      )

    request =
      Protocol.request(rpc_id, "session/request_permission", %{
        "sessionId" => session_id,
        "toolCall" => tool_call,
        "options" => Protocol.permission_options(decisions, tainted?)
      })

    %{state | pending: Map.put(state.pending, rpc_id, {from, session_id})}
    |> write(request)
  end

  # The call being gated is the one whose `:tool_call` event was emitted a moment ago
  # (same process, so the cast carrying it is already in this server's mailbox ahead of
  # the call that got us here). A synthesized id is the fallback for a gate that somehow
  # ran without one, which would otherwise mean a permission request referring to no
  # tool call at all.
  defp tool_call_id(%{tools: []}, name), do: "call_#{name}_unannounced"
  defp tool_call_id(%{tools: tools}, _name), do: List.last(tools).id

  defp notes(tainted?, policy_reason, risks) do
    %{}
    |> put_note("taint", tainted? && Prompt.taint_note())
    |> put_note("policy", Prompt.policy_note(policy_reason))
    |> put_note("scope", Prompt.scope_note(risks || []))
  end

  defp put_note(map, _key, note) when note in [nil, false], do: map
  defp put_note(map, key, note), do: Map.put(map, key, note)

  defp answer_permission(id, message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{from, _session_id}, pending} ->
        GenServer.reply(from, decision(message))
        %{state | pending: pending}
    end
  end

  defp decision(%{"result" => result}) when is_map(result), do: Protocol.decision_from_outcome(result)

  # The editor failed to put the question in front of anyone. Not a refusal, so it
  # carries the same "nobody answered" reason a withdrawn prompt does.
  defp decision(%{"error" => _error}), do: {:deny, Pepe.Permissions.cancelled_reason()}
  defp decision(_other), do: :deny

  ###
  ### plumbing
  ###

  defp put_session(state, session_id, session),
    do: %{state | sessions: Map.put(state.sessions, session_id, session)}

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp reply_error(state, id, kind, message),
    do: write(state, Protocol.error(id, Protocol.error_code(kind), message))

  defp write(state, message) do
    state.writer.(Jason.encode!(message))
    state
  rescue
    # The pipe is gone (the editor exited). Nothing to report it to, and the read loop
    # is about to see EOF and shut the connection down anyway.
    e -> log_write_failure(e, state)
  end

  defp log_write_failure(exception, state) do
    Logger.debug("[acp] could not write to the client: #{Exception.message(exception)}")
    state
  end
end
