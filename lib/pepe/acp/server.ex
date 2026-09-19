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

  alias Pepe.ACP.Content
  alias Pepe.ACP.Protocol
  alias Pepe.ACP.Replay
  alias Pepe.ACP.Sessions
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
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

  @doc """
  The client is gone: let go of everything this connection was holding open (the
  session locks, see `Pepe.ACP.Sessions`), after everything already queued has been
  handled - like `:flush`, a call cannot be served ahead of the lines before it. The
  saved conversations stay exactly where they are.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close, 5_000)

  ###
  ### server callbacks
  ###

  @impl true
  def init(opts) do
    # Off the connection's own path: sweeping the store is housekeeping, and a slow disk
    # must not delay the handshake.
    if Sessions.enabled?(), do: Task.start(&Sessions.prune/0)

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

  def handle_call(:close, _from, state) do
    for {session_id, %{persisted?: true}} <- state.sessions, do: Sessions.release(session_id)
    {:reply, :ok, state}
  end

  def handle_call({:authorize, session_id, name, args, ctx}, from, state) do
    case state.sessions[session_id] do
      # The session went away under a turn that was still running (only reachable if
      # the editor disconnected mid-call). Nobody can be asked, so nothing new runs -
      # the same "nobody answered" reason a timeout gets, not "the user said no".
      nil -> {:reply, {:deny, Pepe.Permissions.cancelled_reason()}, state}
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
    |> write(Protocol.response(id, Protocol.initialize_result(Content.capabilities(state.agent))))
  end

  defp handle_request(_method, id, _params, %{initialized?: false} = state),
    do: reply_error(state, id, :invalid_request, "`initialize` must be the first request on the connection")

  defp handle_request("session/new", id, params, state), do: new_session(id, params, state)
  defp handle_request("session/list", id, params, state), do: list_sessions(id, params, state)
  defp handle_request("session/load", id, params, state), do: reopen_session(:load, id, params, state)
  defp handle_request("session/resume", id, params, state), do: reopen_session(:resume, id, params, state)
  defp handle_request("session/fork", id, params, state), do: fork_session(id, params, state)
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
    with :ok <- check_open_params(params),
         session_id = Sessions.generate_id(),
         {:ok, state} <- open_live(state, session_id, params["cwd"], state.agent, false) do
      write(state, Protocol.response(id, %{"sessionId" => session_id}))
    else
      {:error, kind, message} -> reply_error(state, id, kind, message)
    end
  end

  # What `session/new`, `session/load`, `session/resume` and `session/fork` all take: the
  # directory the editor opened and the MCP servers it wants connected.
  #
  # ONE place, on purpose: connecting client-supplied MCP servers is a single decision
  # for all four methods, made here.
  defp check_open_params(params) do
    cond do
      not is_binary(params["cwd"]) or not absolute?(params["cwd"]) ->
        {:error, :invalid_params, "`cwd` is required and must be an absolute path"}

      # Silently ignoring these would be the worse answer by far: the user configured
      # MCP servers in their editor, and would have no way to find out the agent never
      # connected to any of them. Pepe has its own MCP configuration
      # (`mix pepe mcp add`, stored per agent in ~/.pepe/config.json), which is what
      # actually reaches the model on every other surface too.
      params["mcpServers"] not in [nil, []] ->
        {:error, :invalid_params,
         "this agent does not connect to client-supplied MCP servers; configure them on the agent itself with `pepe mcp add` and they apply on every surface"}

      true ->
        :ok
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute

  # Start (or find) the `Pepe.Agent.Session` behind an ACP session id and register it on
  # this connection. `persist: true` is what makes its history survive the connection:
  # the session saves itself after every change, whatever changed it (a turn, `/undo`,
  # a compaction), so nothing here has to remember to.
  defp open_live(state, session_id, cwd, agent_name, persisted?) do
    key = Sessions.key(session_id)

    case SessionSupervisor.ensure(key, agent_name, persist: Sessions.enabled?()) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(Pepe.PubSub, "session:" <> key)

        # A reopened session's tool-call ids get their own prefix: the history it replays
        # already holds ids from earlier runs, and a fresh `call_1` would be read by the
        # editor as an update to the old `call_1`.
        prefix = if persisted?, do: "call_r#{System.unique_integer([:positive])}", else: "call"
        session = %{key: key, cwd: cwd, run: nil, tools: [], seq: 0, persisted?: persisted?, prefix: prefix}
        {:ok, put_session(state, session_id, session)}

      {:error, reason} ->
        {:error, :internal, "could not start the session: #{inspect(reason)}"}
    end
  end

  ###
  ### session/list, session/load, session/resume, session/fork
  ###

  defp list_sessions(id, params, state) do
    cwd = params["cwd"]

    cond do
      cwd != nil and (not is_binary(cwd) or not absolute?(cwd)) ->
        reply_error(state, id, :invalid_params, "`cwd` must be an absolute path")

      true ->
        case Sessions.page(state.agent, cwd, params["cursor"]) do
          {:ok, metas, next} ->
            sessions = Enum.map(metas, &Protocol.session_info(&1["id"], &1["cwd"], Sessions.title(&1), &1["updated_at"]))
            result = %{"sessions" => sessions}
            write(state, Protocol.response(id, if(next, do: Map.put(result, "nextCursor", next), else: result)))

          {:error, :bad_cursor} ->
            reply_error(state, id, :invalid_params, "unknown `cursor` (use one returned by a previous `session/list`)")
        end
    end
  end

  # `load` streams the whole conversation back before it answers (a client builds its
  # panel from those notifications while the request is still open); `resume` picks the
  # conversation up without replaying it, for a client that already has the thread on
  # screen. Both refuse an id they do not know rather than quietly starting a new one.
  defp reopen_session(kind, id, params, state) do
    with :ok <- check_open_params(params),
         {:ok, session_id, meta} <- fetch_saved(params["sessionId"]),
         :ok <- check_owner(meta, state),
         {:ok, state} <- claim_and_open(state, session_id, meta, params["cwd"]) do
      Sessions.update_cwd(session_id, params["cwd"])
      state = if kind == :load, do: replay(state, session_id), else: state

      state
      |> announce_info(session_id, meta)
      |> write(Protocol.response(id, %{}))
    else
      {:error, code, message} -> reply_error(state, id, code, message)
    end
  end

  defp fork_session(id, params, state) do
    with :ok <- check_open_params(params),
         {:ok, source_id, meta} <- fetch_saved(params["sessionId"]),
         :ok <- check_owner(meta, state),
         new_id = Sessions.generate_id(),
         {:ok, state} <- open_live(state, new_id, params["cwd"], meta["agent"], true),
         :ok <- copy_history(state, source_id, new_id) do
      Sessions.create(new_id, params["cwd"], meta["agent"])
      # A brand-new id nobody else knows: the claim cannot be contested.
      Sessions.claim(new_id)
      write(state, Protocol.response(id, %{"sessionId" => new_id}))
    else
      {:error, kind, message} -> reply_error(state, id, kind, message)
    end
  end

  defp fetch_saved(session_id) do
    case Sessions.fetch(session_id) do
      {:ok, meta} -> {:ok, session_id, meta}
      :error -> {:error, :invalid_params, "unknown `sessionId` (list the saved ones with `session/list`, or start one with `session/new`)"}
    end
  end

  # A conversation belongs to the agent it was held with. Answering it as another agent
  # would splice two personas and two tool sets into one history, and a list that mixes
  # them would offer conversations this connection cannot honestly continue.
  defp check_owner(meta, state) do
    recorded = Sessions.canonical_agent(meta["agent"])
    bound = Sessions.canonical_agent(state.agent)

    cond do
      Config.get_agent(recorded) == nil ->
        {:error, :invalid_params, "the agent this session was held with (`#{recorded}`) no longer exists"}

      recorded != bound ->
        {:error, :invalid_params,
         "this session belongs to agent `#{recorded}`, and this connection is bound to `#{bound}`; open it with `pepe acp #{recorded}`"}

      true ->
        :ok
    end
  end

  # One process at a time may have a saved session open (see `Pepe.ACP.Sessions`). Already
  # open on THIS connection is not a conflict: the editor asked twice, the lock is ours.
  defp claim_and_open(state, session_id, meta, cwd) do
    case state.sessions[session_id] do
      %{} = live ->
        {:ok, put_session(state, session_id, %{live | cwd: cwd})}

      nil ->
        case Sessions.claim(session_id) do
          :ok ->
            case open_live(state, session_id, cwd, meta["agent"], true) do
              {:ok, _state} = opened ->
                opened

              error ->
                Sessions.release(session_id)
                error
            end

          {:error, {:held, pid}} ->
            {:error, :invalid_request,
             "this session is open in another Pepe process#{if pid, do: " (pid #{pid})", else: ""}; close it there, or continue from a copy with `session/fork`"}
        end
    end
  end

  defp replay(state, session_id) do
    messages =
      try do
        Session.history(state.sessions[session_id].key)
      catch
        :exit, _ -> []
      end

    messages
    |> Replay.updates()
    |> Enum.reduce(state, fn update, acc -> write(acc, Protocol.session_update(session_id, update)) end)
  end

  defp announce_info(state, session_id, meta) do
    update = Protocol.session_info_update(title: Sessions.title(meta), updated_at: meta["updated_at"])
    write(state, Protocol.session_update(session_id, update))
  end

  # The new session starts with a copy of the source's conversation. When the source is
  # open here the live process is the truth (`Session.fork/2` also carries its model
  # override); when it is only on disk, the saved history is.
  defp copy_history(state, source_id, new_id) do
    new_key = Sessions.key(new_id)
    source_key = Sessions.key(source_id)

    if Map.has_key?(state.sessions, source_id) do
      case Session.fork(source_key, new_key) do
        {:ok, _key} -> :ok
        {:error, reason} -> {:error, :internal, "could not copy the session: #{inspect(reason)}"}
      end
    else
      case SessionPersistence.load(source_key) do
        {:ok, _agent, messages, pii_map, _pending} ->
          snapshot = %{messages: Pepe.LLM.Message.sanitize_replay(messages), model_override: nil, pii_map: pii_map}
          Session.seed(new_key, snapshot)

        # Nothing was ever saved for it: forking an empty conversation is an empty one.
        :error ->
          :ok
      end
    end
  catch
    :exit, reason -> {:error, :internal, "could not copy the session: #{inspect(reason)}"}
  end

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
        blocks = Content.resolve(params["prompt"], vision?: Content.vision_model?(state.agent), cwd: session.cwd)

        case blocks do
          {:ok, prompt} ->
            state = tell_notes(state, session_id, prompt.notes)
            run_prompt(id, session_id, session, prompt.text, prompt_opts(prompt), state)

          {:error, reason} ->
            reply_error(state, id, :invalid_params, reason)
        end
    end
  end

  # Whatever in the prompt could not be used was reported by `Pepe.ACP.Content` as a note;
  # the person reads it in the reply stream before the answer begins.
  defp tell_notes(state, session_id, notes) do
    Enum.reduce(notes, state, fn note, state ->
      write(state, Protocol.session_update(session_id, Protocol.message_chunk(Content.note_text(note))))
    end)
  end

  # Images ride this turn only, and text that came out of a binary format taints the turn
  # exactly as an attached document does anywhere else.
  defp prompt_opts(prompt) do
    images = if prompt.images == [], do: [], else: [images: prompt.images]
    taint = if prompt.untrusted?, do: [untrusted: true], else: []
    images ++ taint
  end

  defp run_prompt(id, session_id, session, text, extra_opts, state) do
    {session, state} = save_on_first_turn(session_id, session, state)
    server = self()
    stream? = Pepe.Agent.stream_for?(state.agent)

    opts =
      extra_opts ++
        [
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

    # Monitored (not linked - a crashing turn must not take the connection down) so a
    # turn that *exits* instead of returning (the underlying Session GenServer crashing
    # mid-call propagates as an exit out of Pepe.Agent.chat/4) still finishes the
    # request. With no monitor, that exit was invisible here: no {:prompt_done, ...}
    # cast ever arrives, `run` stays set forever, every later prompt is refused as
    # already in flight, and even `session/cancel` cannot recover it.
    ref = Process.monitor(task)
    run = %{request_id: id, stream?: stream?, task: task, monitor_ref: ref}
    put_session(state, session_id, %{session | run: run, tools: []})
  end

  # A session is recorded (and its lock taken) when its first turn starts, not when it is
  # created: an editor opens a session every time its panel opens, and most of them never
  # get a message. Recording those would fill the history list with empty "New thread"
  # entries.
  defp save_on_first_turn(_session_id, %{persisted?: true} = session, state), do: {session, state}

  defp save_on_first_turn(session_id, session, state) do
    if Sessions.enabled?() do
      Sessions.create(session_id, session.cwd, Sessions.canonical_agent(state.agent))
      Sessions.claim(session_id)
      session = %{session | persisted?: true}
      {session, put_session(state, session_id, session)}
    else
      {session, state}
    end
  end

  defp finish_prompt(session_id, result, state) do
    case state.sessions[session_id] do
      %{run: %{} = run} = session ->
        Process.demonitor(run.monitor_ref, [:flush])
        state = put_session(state, session_id, %{session | run: nil, tools: []})
        state = note_turn(state, session_id)
        respond_to_prompt(session_id, run, result, state)

      # A turn that finished after its own cancellation already answered the request,
      # or the task's normal exit reached here as a :DOWN after its own cast already did.
      _ ->
        state
    end
  end

  # The monitored turn task exited without ever casting {:prompt_done, ...} - it
  # crashed rather than returned. A normal completion demonitors before this can
  # arrive (see finish_prompt/3), so reaching here with `reason: :normal` is only a
  # benign race and finish_prompt/3's own no-op clause handles it the same way.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.sessions, fn {_id, s} -> match?(%{run: %{monitor_ref: ^ref}}, s) end) do
      {session_id, _session} -> {:noreply, finish_prompt(session_id, {:error, reason}, state)}
      nil -> {:noreply, state}
    end
  end

  # The session was given a name (it is generated a turn or two in, off the turn's own
  # path): tell the editor, so its history entry stops being the first message's opening.
  def handle_info({:titled, key, title}, state) do
    case Enum.find(state.sessions, fn {_id, session} -> session.key == key end) do
      {session_id, _session} ->
        {:noreply, write(state, Protocol.session_update(session_id, Protocol.session_info_update(title: title)))}

      nil ->
        {:noreply, state}
    end
  end

  # The session topic carries other things (a file ready to send, ...) that are not this
  # connection's business.
  def handle_info(_other, state), do: {:noreply, state}

  # A turn ended, however it ended: the session was used just now. The editor is told
  # (a history panel re-sorts by it), before the answer to the prompt closes the turn.
  defp note_turn(state, session_id) do
    case state.sessions[session_id] do
      %{persisted?: true, key: key} ->
        updated_at = Sessions.touch(session_id, current_agent(key, state.agent))
        write(state, Protocol.session_update(session_id, Protocol.session_info_update(updated_at: updated_at)))

      _ ->
        state
    end
  end

  # The agent the session ended the turn with (a conversation can hand itself to another
  # agent mid-way), so a later `session/list` files it under the right one.
  defp current_agent(key, fallback) do
    Session.status(key).agent
  catch
    :exit, _ -> fallback
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
        #
        # Session.stop/1 is a bare GenServer.call - if the session process is already
        # gone (crashed independently of this cancel, or a cancel racing in before the
        # first turn has finished registering it), that call exits `:noproc`, and
        # since this all runs inside this GenServer's own callback, an uncaught exit
        # here would take the whole connection down with it. Nothing left running is
        # exactly the state a missing session is already in, so there is nothing to do
        # but swallow it.
        try do
          Session.stop(session.key)
        catch
          :exit, _ -> :ok
        end

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
      id = "#{session.prefix}_#{session.seq + 1}"
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
