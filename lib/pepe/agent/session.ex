defmodule Pepe.Agent.Session do
  @moduledoc """
  A live conversation. One GenServer per session key (e.g. `"telegram:12345"` or
  a WebSocket connection id), holding the running message history and the bound
  agent. Concurrency, isolation and crash recovery come for free from OTP.
  """

  # Temporary: a session is never auto-restarted by the supervisor. A crashed
  # conversation just ends (the next message recreates it via `ensure`, reloading any
  # persisted history), and TTL eviction can stop the process without a restart loop.
  # Persisted sessions are re-spawned explicitly on boot by `SessionSupervisor.restore`.
  use GenServer, restart: :temporary

  alias Pepe.Agent.Runtime
  alias Pepe.Agent.SessionTitles
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.LLM
  alias Pepe.LLM.Message

  # Sources that are the owner/operator using their own runtime, not a customer
  # messaging it - never counted or blocked by Pepe.Config.company_message_limit/1.
  # Everything else (telegram, a webhook provider, widget:...) counts by default,
  # so a newly added channel is covered without having to list it here.
  @internal_sources ~w(tui web api)

  ###
  ### client API
  ###

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via(key))
  end

  defp via(key), do: {:via, Registry, {Pepe.Agent.Registry, key}}

  @doc "Send a user message; runs the loop and returns `{:ok, reply}`."
  def chat(key, text, opts \\ []) do
    GenServer.call(via(key), {:chat, text, opts}, :infinity)
  end

  @doc "Reset the conversation history (keeps the system prompt)."
  def reset(key), do: GenServer.call(via(key), :reset)

  @doc """
  Ask the session to clear its context **after the current turn** - how an agent
  ends its own conversation (the `end_session` tool). The in-flight reply is still
  delivered; the next message starts fresh.
  """
  def end_session(key), do: GenServer.cast(via(key), :end_session)

  @doc "Return the current message history."
  def history(key), do: GenServer.call(via(key), :history)

  @doc "Switch the bound agent."
  def set_agent(key, agent_name), do: GenServer.call(via(key), {:set_agent, agent_name})

  @doc """
  Override the model connection for this session only - the agent's own config on
  disk is never touched. `model_name` is a connection name (as stored on
  `Pepe.Config.Agent.model`); pass `nil` to clear the override and fall back to the
  agent's own model. Deliberately in-memory only (lost on process restart) - a
  "just for now" experiment, not a durable setting.
  """
  def set_model(key, model_name), do: GenServer.call(via(key), {:set_model, model_name})

  # Internal-only variant used by the triage downgrade - see the handle_call clause.
  defp set_model_if_unset(key, model_name), do: GenServer.call(via(key), {:set_model_if_unset, model_name})

  @doc """
  Whether this session currently waives its surface's normal "must be addressed"
  gate (e.g. Telegram's @mention-in-groups requirement - see `mention_optional?/1`
  and Gateways.Telegram's `/mention` command). Lives on the session, not the bot, so
  toggling it in one group chat never affects any other; `reset/1` clears it back to
  the default (required), the same way a fresh conversation forgets everything else
  turn-scoped.
  """
  @spec mention_optional?(term()) :: boolean()
  def mention_optional?(key), do: GenServer.call(via(key), :mention_optional?)

  @doc "Set/clear this session's mention-optional waiver (see `mention_optional?/1`)."
  @spec set_mention_optional(term(), boolean()) :: :ok
  def set_mention_optional(key, waived?), do: GenServer.call(via(key), {:set_mention_optional, waived?})

  @doc "Drop the last user turn (and its responses) from the history."
  @spec undo(term()) :: :ok
  def undo(key), do: GenServer.call(via(key), :undo)

  @doc "Cancel the in-flight run for this session, if any."
  @spec stop(term()) :: :ok | {:error, :not_running}
  def stop(key), do: GenServer.call(via(key), :stop)

  @doc """
  Fold `text` into the turn already running (the `/inline` command): it's picked up as
  a user message before the next model call of that same turn, instead of waiting in
  the queue. Returns `{:error, :not_running}` when nothing is in flight (send it as a
  normal `chat/3` message instead).
  """
  @spec inline(term(), String.t()) :: :ok | {:error, :not_running}
  def inline(key, text), do: GenServer.call(via(key), {:inline, text})

  @doc """
  Fork this session into `new_key`: the new session starts with a copy of this
  conversation's history (plus this session's model override and PII map) and then
  evolves independently - the original is left untouched. Branching a conversation
  to explore a different direction without losing where you were. Used by the
  dashboard `/fork`. Returns `{:ok, new_key}` or `{:error, reason}`.
  """
  @spec fork(term(), term()) :: {:ok, term()} | {:error, term()}
  def fork(key, new_key), do: GenServer.call(via(key), {:fork, new_key})

  # Replace a session's history (and overrides) with a snapshot - the seeding half of
  # fork/2, called on the freshly-spawned branch. Internal.
  @doc false
  def seed(key, snapshot), do: GenServer.call(via(key), {:seed, snapshot})

  @doc """
  Resume a turn that was cut off mid-run by a process restart (a `pending` marker
  survived to this session's init - see `Pepe.Agent.SessionPersistence`). Runs an
  internal, invisible prompt referencing the interrupted message and returns
  whatever the agent replies; like `heartbeat/1`, only the reply joins the visible
  history, not the internal prompt. Returns `{:ok, text}`, `:nothing_pending` (the
  session ended cleanly, nothing to resume), or `{:error, reason}`.
  """
  @spec resume(term()) :: {:ok, String.t()} | :nothing_pending | {:error, term()}
  def resume(key), do: GenServer.call(via(key), :resume, 120_000)

  @doc "Run the memory/skill review now over this session (the `/learn` trigger)."
  @spec learn(term()) :: :ok | {:error, :no_agent | :not_allowed}
  def learn(key), do: GenServer.call(via(key), :learn)

  @doc """
  Run one heartbeat pulse on this session's live context - the agent decides, on its
  own, whether anything is worth proactively saying. Returns `{:ok, text}` when it
  wants to speak, `:silent` when it chose not to, or `{:error, reason}`
  (`:busy` when a normal turn is already running - the pulse is simply skipped).
  """
  @spec heartbeat(term()) :: {:ok, String.t()} | :silent | {:error, term()}
  def heartbeat(key), do: GenServer.call(via(key), :heartbeat, 120_000)

  @doc "Return `%{agent:, model:, turns:}` for the session."
  def status(key), do: GenServer.call(via(key), :status)

  @doc "Summarize older turns into one message to free up context."
  @spec compact(term()) :: {:ok, String.t()} | {:error, term()}
  def compact(key), do: GenServer.call(via(key), :compact, :infinity)

  @doc """
  Answer a one-off **side question** against the live context without recording it.

  The question and the reply are run on top of the current history but are *not*
  stored, so they never influence future turns - this powers the Telegram `/btw`
  (a.k.a. `/side`) command. Returns `{:ok, reply}` or `{:error, reason}`.
  """
  @spec aside(term(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def aside(key, text, opts \\ []), do: GenServer.call(via(key), {:aside, text, opts}, :infinity)

  ###
  ### server
  ###

  alias Pepe.Agent.SessionPersistence

  # An anonymous widget visitor's tab left open doesn't need to hold a live session
  # (or accumulate on disk) forever - see the moduledoc note on `init/1`'s merge.
  @widget_idle_ttl_ms 30 * 60_000

  @doc false
  @spec default_ephemeral?(String.t()) :: boolean()
  def default_ephemeral?(key), do: String.starts_with?(key, "widget:")

  @doc false
  @spec default_ttl_ms(String.t()) :: pos_integer() | nil
  def default_ttl_ms(key), do: if(default_ephemeral?(key), do: @widget_idle_ttl_ms, else: nil)

  @impl true
  def init(opts) do
    key = Keyword.fetch!(opts, :key)
    default_agent = Keyword.get(opts, :agent_name) || Config.default_agent_name()

    state =
      case persist?() && SessionPersistence.load(key) do
        {:ok, name, messages, pending} ->
          # A crash mid-tool-call can persist an assistant turn whose tool calls were
          # never answered; replaying it as-is makes the model loop. Repair it first.
          messages = Pepe.LLM.Message.sanitize_replay(messages)
          %{key: key, agent_name: name || default_agent, messages: messages, running: nil, pending_resume: pending}

        _ ->
          %{
            key: key,
            agent_name: default_agent,
            messages: init_messages(default_agent),
            running: nil,
            idle_ref: nil,
            pending_resume: nil
          }
      end

    # `learn_allowed` gates the memory/skill review for THIS conversation. The
    # surface sets it per turn (Telegram computes it from the bot's `trainers`
    # allowlist + the sender), so a client's chat never becomes memory. Defaults to
    # true (an owner console/API conversation learns unless told otherwise).
    #
    # `ttl_ms` evicts the session after that much inactivity (nil = never, the
    # default). `ephemeral` skips persistence and clears on eviction - used by
    # customer-facing channels so support conversations don't accumulate. Falls back
    # to a key-derived default (see `default_ephemeral?/1`), not just `false`: a
    # session is a Registry-wide singleton keyed by `key` - "the already-running
    # session keeps the options it was created with" (see SessionSupervisor.ensure/3)
    # means whichever caller reaches `ensure/3` FIRST for a given key wins, and not
    # every caller passes ephemeral/ttl_ms explicitly (e.g. the dashboard's own
    # session viewer just wants to look at whatever's there). Deriving the default
    # from the key itself makes the policy the key's own property, not a race.
    state =
      state
      |> Map.put_new(:idle_ref, nil)
      |> Map.put_new(:learn_allowed, true)
      |> Map.put_new(:model_override, nil)
      |> Map.put_new(:mention_optional, false)
      # Messages sent while a turn is running wait here (FIFO) and run right after it,
      # instead of being rejected - each carries its caller's `from` so the reply lands
      # with whoever sent it. See handle_call({:chat...}) below.
      |> Map.put_new(:queue, [])
      |> Map.merge(%{
        ttl_ms: Keyword.get(opts, :ttl_ms, default_ttl_ms(key)),
        ephemeral: Keyword.get(opts, :ephemeral, default_ephemeral?(key)),
        reset_pending: false,
        ttl_ref: nil,
        # Reversible redaction map (pseudonym -> real) accumulated by inbound hooks and
        # applied to outbound replies. Lives only in this process; cleared on reset.
        pii_map: []
      })

    {:ok, arm_ttl(state)}
  end

  # Sessions are only persisted in long-running surfaces (serve/gateway), so local
  # `run`/`tui` and tests don't write files. The :env check is a hard backstop on
  # top of :persist_sessions - a test that inadvertently ends up with that flag
  # true (a stray `with_app(serve: true, ...)` call, a race on the shared
  # Application env between concurrent test files, ...) must never be able to
  # write into a real ~/.pepe.
  defp persist?,
    do: Application.get_env(:pepe, :env) != :test and Application.get_env(:pepe, :persist_sessions, false)

  defp persist(state) do
    if persist?() and not Map.get(state, :ephemeral, false),
      do: SessionPersistence.save(state.key, state.agent_name, state.messages)

    state
  end

  # Mark a turn as in flight right before running it, so a crash mid-turn leaves a
  # durable trace `Pepe.Agent.SessionSupervisor.restore/0` can pick up on the next
  # boot. Same persist?/ephemeral guard as `persist/1`.
  defp mark_pending(state, text) do
    if persist?() and not Map.get(state, :ephemeral, false), do: SessionPersistence.mark_pending(state.key, text)
  end

  # A run ended without going through the normal `persist/1` path (stopped, crashed,
  # or errored) - clear the pending marker on disk too, so it isn't mistaken for an
  # interrupted turn on the next boot.
  defp clear_pending(state) do
    if persist?() and not Map.get(state, :ephemeral, false), do: SessionPersistence.clear_pending(state.key)
    %{state | pending_resume: nil}
  end

  defp resume_prompt(pending_text) do
    """
    [Automatic recovery - the user does not see this note, only your reply if you send one.]

    The conversation was interrupted by a server restart before you could respond to the user's last message:

    "#{pending_text}"

    You may have already taken some action for it before being cut off. If you're unsure whether something \
    risky was already done (a message sent, a file changed, an email sent), check before repeating it rather \
    than assuming a clean slate. Pick up naturally from here and reply to the user now.
    """
  end

  # Seed a session with the system prompt built from the agent's CURRENT config/soul.
  # Called at session start and on /new (reset), so a fresh session always picks up
  # the latest persona/config - a live session keeps its prompt stable until then.
  defp init_messages(agent_name) do
    case agent_name && Config.get_agent(agent_name) do
      nil -> []
      agent -> [Message.system(Workspace.system_prompt(agent))]
    end
  end

  # One run at a time per session. While a run is in flight, a new message is
  # rejected with `:busy` (the caller can `/stop` it) rather than interleaving.
  @impl true
  def handle_call({:chat, text, opts}, from, %{running: %{}} = state) do
    # A turn is already running: queue this one to run right after (FIFO), holding the
    # caller's `from` so it gets its reply when its turn runs. `/inline` is the escape
    # hatch to fold a message into the running turn instead of waiting.
    {:noreply, %{state | queue: state.queue ++ [{from, text, opts}]}}
  end

  def handle_call({:chat, text, opts}, from, state), do: start_turn(state, text, opts, from)

  def handle_call(:stop, _from, %{running: %{}} = state) do
    # Stop cancels the in-flight turn and drops anything queued behind it.
    {:reply, :ok, state |> cancel_queue({:error, :stopped}) |> cancel_running({:error, :stopped})}
  end

  def handle_call(:stop, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call({:inline, text}, _from, %{running: %{task: pid}} = state) do
    send(pid, {:steer, text})
    {:reply, :ok, state}
  end

  def handle_call({:inline, _text}, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call({:fork, new_key}, _from, state) do
    # Spawn the branch under its own key (same agent), then seed it with a snapshot of
    # this conversation. Running in the source process, so `seed` is a call to a
    # *different* GenServer - no self-deadlock. This session is left as-is.
    case Pepe.Agent.SessionSupervisor.ensure(new_key, state.agent_name) do
      {:ok, _pid} ->
        snapshot = %{messages: state.messages, model_override: state.model_override, pii_map: state.pii_map}
        :ok = seed(new_key, snapshot)
        {:reply, {:ok, new_key}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:seed, snapshot}, _from, state) do
    state = %{state | messages: snapshot.messages, model_override: snapshot.model_override, pii_map: snapshot.pii_map}
    {:reply, :ok, persist(state)}
  end

  def handle_call(:learn, _from, %{learn_allowed: false} = state) do
    {:reply, {:error, :not_allowed}, state}
  end

  def handle_call(:learn, _from, state) do
    case Config.get_agent(state.agent_name) || Config.default_agent() do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        Pepe.Agent.Reflect.review_async(agent, state.messages)
        {:reply, :ok, cancel_idle(state)}
    end
  end

  def handle_call(:resume, _from, %{pending_resume: nil} = state) do
    {:reply, :nothing_pending, state}
  end

  def handle_call(:resume, _from, %{running: %{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:resume, _from, state) do
    case resolve_agent(state) do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        # Own the trace here too (same reasoning as spawn_run): started BEFORE the
        # inbound hook, with the raw text as a placeholder, so the hook's own
        # Trace.event/1 call actually lands instead of silently no-op'ing on a
        # not-yet-started trace. Runtime.run then sees :nested and leaves finishing
        # to this handler.
        Pepe.Trace.start(agent.name, state.key, state.pending_resume, "resume")

        # The interrupted text is real user input captured before the crash, so it
        # goes through the same inbound/outbound redaction hooks a normal turn
        # applies (spawn_run) - a resume must not be the one path that leaks PII a
        # configured hook would otherwise have caught.
        {redacted, entries} = Pepe.Hooks.transform(:inbound, state.pending_resume, agent, %{"map" => state.pii_map})
        Pepe.Trace.set_prompt(redacted)

        messages =
          ensure_system(state.messages, agent) ++
            goal_reminder(state.key) ++ [Message.user(resume_prompt(redacted))]

        opts = [session_key: state.key]

        Pepe.Hooks.start_map(state.pii_map ++ entries)

        case Runtime.run(agent, messages, opts) do
          {:ok, reply, _all} = result ->
            Pepe.Trace.finish(result)
            map = Pepe.Hooks.take_map()
            {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
            text = Pepe.Hooks.restore(shown, map)

            # Only the agent's own reply joins the visible history - the internal
            # recovery note stays invisible, like a heartbeat pulse.
            new_state = %{
              state
              | messages: state.messages ++ [Message.assistant(text)],
                pending_resume: nil,
                pii_map: map
            }

            {:reply, {:ok, text}, persist(new_state)}

          {:error, reason} = result ->
            Pepe.Hooks.take_map()
            Pepe.Trace.finish(result)
            {:reply, {:error, reason}, clear_pending(state)}
        end
    end
  end

  # Skip a pulse outright while a normal turn is in flight - never collide with it.
  def handle_call(:heartbeat, _from, %{running: %{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:heartbeat, _from, state) do
    case resolve_agent(state) do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        prompt = Pepe.Heartbeat.build_prompt(state.key, agent.name)
        messages = ensure_system(state.messages, agent) ++ [Message.user(prompt)]
        opts = [session_key: state.key]

        # The pulse prompt itself is internal (never user text, so no inbound
        # transform), but the agent can still call tools during a heartbeat - same
        # tool_result protection and restore as a normal turn.
        Pepe.Hooks.start_map(state.pii_map)

        case Runtime.run(agent, messages, opts) do
          {:ok, reply, _all} ->
            handle_pulse_reply(reply, agent, state)

          {:error, reason} ->
            Pepe.Hooks.take_map()
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:aside, text, opts}, _from, state) do
    case resolve_agent(state) do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        # An aside is real user text on its way to the provider, so it gets the same
        # inbound/outbound redaction a normal turn does (spawn_run/resume) - it must not be the
        # one path that leaks PII a configured hook would have caught, or leaves tool-result
        # hook entries stranded in the process dictionary. It stays ephemeral: `state` (its
        # `pii_map` included) is left untouched, so the aside changes nothing about the session.
        {redacted, entries} = Pepe.Hooks.transform(:inbound, text, agent, %{"map" => state.pii_map})
        messages = ensure_system(state.messages, agent) ++ [Message.user(redacted)]
        opts = Keyword.put(opts, :session_key, state.key)

        Pepe.Hooks.start_map(state.pii_map ++ entries)

        case Runtime.run(agent, messages, opts) do
          {:ok, reply, _all} ->
            map = Pepe.Hooks.take_map()
            {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
            {:reply, {:ok, Pepe.Hooks.restore(shown, map)}, state}

          {:error, reason} ->
            Pepe.Hooks.take_map()
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    # A fresh conversation cancels any in-flight run (so a stuck one can't leave the
    # session wedged) and any queued turns, and forgets "allow for this session" grants.
    Pepe.Permissions.SessionStore.clear(state.key)
    state = state |> cancel_queue({:error, :stopped}) |> cancel_running({:error, :stopped})

    {:reply, :ok, persist(%{state | messages: init_messages(state.agent_name), pii_map: [], mention_optional: false})}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call({:set_agent, agent_name}, _from, state) do
    {:reply, :ok, persist(%{state | agent_name: agent_name, messages: init_messages(agent_name)})}
  end

  # Not `persist/1`-wrapped: SessionPersistence only saves agent_name/messages, and
  # a model override is deliberately ephemeral - reverting to the agent's own model
  # on a process restart is correct, not a bug.
  def handle_call({:set_model, model_name}, _from, state) do
    {:reply, :ok, %{state | model_override: model_name}}
  end

  # Same effect as :set_model, but only when nothing else already set an override -
  # used by the triage downgrade below so it can never clobber an explicit /model
  # the caller issued while a triage classification (up to @triage_timeout_ms) was
  # still in flight for the current turn.
  def handle_call({:set_model_if_unset, model_name}, _from, %{model_override: nil} = state) do
    {:reply, :ok, %{state | model_override: model_name}}
  end

  def handle_call({:set_model_if_unset, _model_name}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:mention_optional?, _from, state) do
    {:reply, state.mention_optional, state}
  end

  # Not `persist/1`-wrapped, same reasoning as :set_model: a live-conversation
  # waiver, not a durable setting - reverting to "must be addressed" on a process
  # restart is correct, not a bug (and :reset clears it explicitly too, see above).
  def handle_call({:set_mention_optional, waived?}, _from, state) do
    {:reply, :ok, %{state | mention_optional: waived?}}
  end

  def handle_call(:undo, _from, state) do
    {:reply, :ok, persist(%{state | messages: drop_last_turn(state.messages)})}
  end

  def handle_call(:status, _from, state) do
    turns = Enum.count(state.messages, &(&1["role"] == "user"))

    {:reply, %{agent: state.agent_name, model: model_id(state.agent_name, state.model_override), turns: turns}, state}
  end

  def handle_call(:compact, _from, state) do
    case state.agent_name && Config.get_agent(state.agent_name) do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        agent = apply_model_override(agent, state.model_override)
        # Review before compacting, while the full detail is still here.
        if state.learn_allowed, do: Pepe.Agent.Reflect.review_async(agent, state.messages)

        case Pepe.Agent.Compaction.compact_now(state.messages, Config.model_for_agent(agent)) do
          {:ok, messages, summary} ->
            {:reply, {:ok, summary}, persist(%{state | messages: messages})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp start_chat_run(state, agent, company, counts?, text, opts, from) do
    if counts?, do: Pepe.Usage.record_message(company)

    # Tag the run with this session's key so `:session` approvals are scoped to it.
    opts = Keyword.put(opts, :session_key, state.key)
    # Whether this conversation may feed the memory/skill review (set by the surface).
    state = %{state | learn_allowed: Keyword.get(opts, :learn, state.learn_allowed)}
    # A new message cancels any pending idle review and re-arms the TTL.
    state = state |> cancel_idle() |> arm_ttl()
    # Run off-process so the session stays responsive (e.g. to `/stop`). The raw
    # user text and the reversible map go in; the task redacts (inbound hooks)
    # before the model sees anything and restores the reply on the way out.
    base = state.messages |> ensure_system(agent) |> maybe_add_lang_hint(opts, state.messages)
    mark_pending(state, text)
    # Complexity-triage only ever runs on a session's first-ever turn (same
    # boundary as the lang hint above), never when a model override is already
    # in play (an explicit `/model` switch always wins over an automatic one),
    # and only when there's actually somewhere to downgrade to on a SIMPLE
    # verdict.
    should_triage? =
      agent.triage_model && agent.simple_model && is_nil(state.model_override) &&
        first_turn?(state.messages)

    {pid, ref} = spawn_run(state.key, agent, base, text, state.pii_map, opts, should_triage?)

    running = %{task: pid, ref: ref, from: from, on_event: opts[:on_event]}
    {:noreply, %{state | running: running, pending_resume: text}}
  end

  # True on a session's first-ever turn: an empty history or just the base system prompt.
  defp first_turn?(messages), do: Enum.count_until(messages, 2) <= 1

  defp handle_pulse_reply(reply, agent, state) do
    map = Pepe.Hooks.take_map()

    if Pepe.Heartbeat.silent?(reply) do
      {:reply, :silent, %{state | pii_map: map}}
    else
      {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
      text = Pepe.Hooks.restore(shown, map)

      # Only the agent's own message joins the visible history - the
      # internal pulse prompt stays invisible, like a cron/system trigger.
      new_state = %{state | messages: state.messages ++ [Message.assistant(text)], pii_map: map}
      {:reply, {:ok, text}, persist(new_state)}
    end
  end

  # A finished run reports here. Reply to the waiting caller and absorb the new
  # history. A stale `:run_done` (the run was stopped meanwhile) is ignored.
  @impl true
  def handle_info({:run_done, result, agent_name}, %{running: %{from: from, ref: ref} = running} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, reply, all_messages, entries} ->
          GenServer.reply(from, {:ok, reply})

          # If the agent called `end_session` this turn, clear the context (and the
          # reversible map) now that the reply is out - the next message starts fresh.
          {messages, pii_map} =
            if state.reset_pending,
              do: {init_messages(agent_name), []},
              else: {all_messages, state.pii_map ++ entries}

          state =
            %{
              state
              | agent_name: agent_name,
                messages: messages,
                running: nil,
                reset_pending: false,
                pii_map: pii_map,
                pending_resume: nil
            }
            |> persist()
            |> maybe_schedule_idle()

          # Only now is the turn actually in `state.messages`. The runtime's `:done`
          # fired much earlier, from inside the run task and before outbound redaction
          # (which can itself call a model), so a listener that re-reads history on
          # `:done` reads it one turn stale. `:committed` is the event to reconcile on.
          emit(running[:on_event], :committed)
          maybe_title(state)
          state

        {:error, reason} ->
          GenServer.reply(from, {:error, reason})
          clear_pending(%{state | running: nil})
      end

    {:noreply, run_next(state)}
  end

  def handle_info({:run_done, _result, _agent_name}, state), do: {:noreply, state}

  # The run task died without reporting (external kill, unexpected exit). Recover the
  # session so it isn't pinned on `:busy`, and unblock the waiting caller.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{running: %{ref: ref, from: from}} = state
      ) do
    GenServer.reply(from, {:error, :stopped})
    {:noreply, run_next(clear_pending(%{state | running: nil}))}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # The session went idle after a run - run the memory/skill review if this
  # conversation is allowed to learn, then clear the timer.
  def handle_info(:idle_review, state) do
    with true <- state.learn_allowed,
         agent when not is_nil(agent) <- Config.get_agent(state.agent_name) do
      Pepe.Agent.Reflect.review_async(agent, state.messages)
    end

    {:noreply, %{state | idle_ref: nil}}
  end

  # The session sat idle past its TTL - stop the process to free memory. An
  # ephemeral session also drops its persisted history.
  def handle_info(:ttl_expire, state), do: {:stop, :normal, maybe_clear(state)}

  # An agent ended its own conversation - mark it so `:run_done` clears the context
  # once the current reply is delivered.
  @impl true
  def handle_cast(:end_session, state), do: {:noreply, %{state | reset_pending: true}}

  # TTL eviction: re-armed on every message; nil ttl_ms = never expire.
  defp arm_ttl(%{ttl_ms: ms} = state) when is_integer(ms) and ms > 0 do
    state = cancel_ttl(state)
    %{state | ttl_ref: Process.send_after(self(), :ttl_expire, ms)}
  end

  defp arm_ttl(state), do: state

  defp cancel_ttl(%{ttl_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | ttl_ref: nil}
  end

  defp cancel_ttl(state), do: state

  defp maybe_clear(%{ephemeral: true, key: key} = state) do
    if persist?(), do: SessionPersistence.delete(key)
    state
  end

  defp maybe_clear(state), do: state

  # Idle-review timer (fires the reflect pass a while after the last turn).
  @idle_ms 90_000

  defp maybe_schedule_idle(%{learn_allowed: true} = state) do
    state = cancel_idle(state)
    %{state | idle_ref: Process.send_after(self(), :idle_review, @idle_ms)}
  end

  defp maybe_schedule_idle(state), do: state

  defp cancel_idle(%{idle_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  defp cancel_idle(state), do: state

  # Cancel the in-flight run (if any): drop the monitor, kill the task, and unblock
  # the waiting caller with `reply`. Used by `/stop` and `/new`.
  defp cancel_running(%{running: %{task: pid, ref: ref, from: from}} = state, reply) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    GenServer.reply(from, reply)
    clear_pending(%{state | running: nil})
  end

  defp cancel_running(state, _reply), do: state

  # Reply `reply` to every caller waiting in the queue and clear it, so a stop/reset
  # doesn't leave them blocked until their GenServer.call times out.
  defp cancel_queue(%{queue: queue} = state, reply) do
    Enum.each(queue, fn {from, _text, _opts} -> GenServer.reply(from, reply) end)
    %{state | queue: []}
  end

  # Resolve the agent fresh each turn (fall back to the default if it was renamed, and
  # apply this session's model override), so tools/model changes apply live. Replies an
  # error to `from` directly on a failure so it works both as a direct call and when
  # draining the queue. Returns `{:noreply, state}` (running set on success).
  defp start_turn(state, text, opts, from) do
    case resolve_agent(state) do
      nil ->
        GenServer.reply(from, {:error, :no_agent})
        {:noreply, state}

      agent ->
        company = Pepe.Company.of(agent.name)
        counts? = customer_message?(state.key, agent)

        if counts? and Pepe.Usage.over_message_limit?(company) do
          GenServer.reply(from, {:error, :message_limit_exceeded})
          {:noreply, state}
        else
          start_chat_run(state, agent, company, counts?, text, opts, from)
        end
    end
  end

  # A run's `:on_event` is optional, and a listener that crashes on an event it doesn't
  # know must not take the session down with it.
  # Name the conversation once, from its opening message, on the agent's utility model.
  #
  # After the first exchange and not before: a session named from the first message alone
  # would be named from "hi". After the first *answer* the conversation has a subject.
  #
  # In a task, because this process has queued turns waiting on it and a title is worth
  # nothing next to the next reply. Fire and forget: nothing reads a title but a human, so a
  # title that never arrives costs nothing. With a `utility_model` a cheap model writes the
  # name; with none, the opening message is trimmed into one, for free (Pepe.Agent.Utility).
  defp maybe_title(%{key: key, agent_name: agent_name, messages: messages}) do
    with 1 <- Enum.count(messages, &(&1["role"] == "user")),
         nil <- SessionTitles.get(key),
         %{} = agent <- Config.get_agent(agent_name),
         %{"content" => first} when is_binary(first) <-
           Enum.find(messages, &(&1["role"] == "user")) do
      Task.start(fn -> title_now(key, agent, first) end)
    end

    :ok
  end

  defp title_now(key, agent, first) do
    case SessionTitles.generate(key, agent, first) do
      {:ok, title} -> Phoenix.PubSub.broadcast(Pepe.PubSub, "session:" <> key, {:titled, key, title})
      :skip -> :ok
    end
  end

  defp emit(fun, event) when is_function(fun, 1) do
    fun.(event)
    :ok
  rescue
    _ -> :ok
  end

  defp emit(_fun, _event), do: :ok

  # After a turn ends, start the next queued one (if any). A queued turn that fails to
  # start (agent gone / limit) has already replied its error, so we just try the next.
  defp run_next(%{queue: [], running: nil} = state), do: state
  defp run_next(%{running: %{}} = state), do: state

  defp run_next(%{queue: [{from, text, opts} | rest]} = state) do
    case start_turn(%{state | queue: rest}, text, opts, from) do
      {:noreply, %{running: %{}} = started} -> started
      {:noreply, idle} -> run_next(idle)
    end
  end

  defp run_next(state), do: state

  # Complexity triage is best-effort only: it must never make a turn wait longer
  # than this, and a slow/unreachable triage model is treated the same as a
  # "not simple" verdict (i.e. do nothing), never surfaced as an error.
  @triage_timeout_ms 6_000

  # Fixed, Pepe-authored classification prompt - no per-agent policy to configure,
  # unlike a real agent's own system prompt. Plain-text sentinel verdict (only
  # "SIMPLE" is ever looked for in the reply), the same convention
  # Pepe.Heartbeat.silent?/1 already uses instead of structured output.
  @triage_prompt """
  Classify the complexity of the user's message that follows. Reply with exactly \
  one word and nothing else: SIMPLE if it is a quick, everyday question a basic \
  model can answer well; COMPLEX if it needs deep reasoning, multi-step planning, \
  or expert-level knowledge to answer well.
  """

  # A raw, one-off classification call directly against a model connection - no
  # agent, no session, no tools. Returns :simple, :complex, or :failed (no such
  # model, unreachable, or slower than @triage_timeout_ms - always treated the
  # same as :complex by the caller, i.e. proceed on the agent's own model
  # unchanged, but kept distinct here so it shows up honestly on the trace).
  defp triage_verdict(triage_model_name, text) do
    task =
      Task.async(fn ->
        try do
          case Config.get_model(triage_model_name) do
            nil -> {:error, :no_such_model}
            model -> LLM.chat(model, [Message.system(@triage_prompt), Message.user(text)])
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "triage #{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, @triage_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{content: content}}} ->
        if content |> to_string() |> String.trim() |> String.upcase() =~ "SIMPLE", do: :simple, else: :complex

      _ ->
        :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  # Run the loop in an unlinked, monitored process so a crash or a `/stop` kill can't
  # take the session down. It always reports back, turning a raise/exit into `{:error, _}`.
  defp spawn_run(key, agent, base_messages, text, pii_map, opts, should_triage?) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result =
          try do
            # Own the trace here (rather than leaving Runtime.run to start its own)
            # so hook activity and a triage verdict - both of which happen before
            # Runtime.run is even called - fold into the same trace instead of
            # being invisible. Started BEFORE redaction (with the raw text as a
            # placeholder prompt) so the inbound hook's own event below actually
            # gets recorded; set_prompt/1 corrects the recorded prompt to the
            # redacted text right after, so what ends up on disk never differs
            # from today's behavior. Runtime.run's own Trace.start then always
            # sees :nested and never finishes it, so this spawned task is now the
            # sole owner: finish is called unconditionally below, matching what
            # Runtime.run used to do for this exact call.
            Pepe.Trace.start(agent.name, opts[:session_key], text, opts[:source])

            # Inbound hooks redact the user text (and grow the reversible map) before
            # the model - off the GenServer, so an LLM-backed redactor never blocks it.
            # Triage below sees this same redacted text, never the raw one.
            {redacted, entries} = Pepe.Hooks.transform(:inbound, text, agent, %{"map" => pii_map})
            Pepe.Trace.set_prompt(redacted)

            # A SIMPLE verdict downgrades THIS turn's model right away (the same
            # struct-field swap apply_model_override/2 uses) and, via the public
            # set_model_if_unset/2 API, makes it stick for every later turn too - the
            # session GenServer's mailbox is free to service that call because
            # handle_call({:chat, ...}) already replied :noreply before this task
            # started (the same reason /stop works mid-turn). The "if unset" variant
            # is deliberate: an explicit /model issued while this triage call was
            # still in flight must win over the downgrade, not get silently
            # overwritten by it. Anything else (COMPLEX, or triage failing open)
            # leaves the agent on its own already-configured model, unchanged.
            agent =
              if should_triage? do
                case triage_verdict(agent.triage_model, redacted) do
                  :simple ->
                    Pepe.Trace.event({:triage, :simple, agent.triage_model, agent.simple_model})
                    set_model_if_unset(key, agent.simple_model)
                    %{agent | model: agent.simple_model}

                  verdict ->
                    Pepe.Trace.event({:triage, verdict, agent.triage_model, nil})
                    agent
                end
              else
                agent
              end

            # A goal/plan reminder is prepended to *this call only*, right before the
            # user's turn - never persisted, so it always reflects the live state
            # instead of freezing a snapshot into history (see Focus.context_line/1).
            reminder = goal_reminder(key)
            call_messages = base_messages ++ reminder ++ [Message.user(redacted)]

            # Seed the tool_result redaction accumulator with what's already known
            # (session history + this turn's inbound entries) so a tool call that
            # surfaces a name already tokenized earlier in the conversation reuses
            # the same token. Tools.execute grows it as calls happen during the run.
            Pepe.Hooks.start_map(pii_map ++ entries)

            case Runtime.run(agent, call_messages, opts) do
              {:ok, reply, all_messages} ->
                new_turn = Enum.drop(all_messages, length(base_messages) + length(reminder))
                map = Pepe.Hooks.take_map()
                new_entries = Enum.drop(map, length(pii_map))
                {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
                {:ok, Pepe.Hooks.restore(shown, map), base_messages ++ new_turn, new_entries}

              other ->
                Pepe.Hooks.take_map()
                other
            end
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, "run #{kind}: #{inspect(reason)}"}
          end

        Pepe.Trace.finish(result)
        send(parent, {:run_done, result, agent.name})
      end)

    {pid, Process.monitor(pid)}
  end

  # Whether this turn is a real customer message against the company's monthly
  # message cap - not the owner's own TUI console, dashboard test chat, or direct
  # API use, and not an agent explicitly exempted from the cap.
  defp customer_message?(key, agent) do
    not agent.exempt_message_limit and Pepe.Trace.source_from_session(key) not in @internal_sources
  end

  # Wrapped as a <system-reminder> user-turn (not a second "system" message) so it
  # reaches every provider the same way - the Anthropic adapter only ever looks at
  # the *first* system-role message and silently drops any later one.
  defp goal_reminder(key) do
    case Pepe.Session.Focus.context_line(key) do
      nil -> []
      line -> [Message.user("<system-reminder>\n#{line}\n</system-reminder>")]
    end
  end

  # A session started before any agent existed has no system message yet - seed one.
  defp ensure_system([%{"role" => "system"} | _] = messages, _agent), do: messages

  defp ensure_system(messages, agent),
    do: [Message.system(Workspace.system_prompt(agent)) | messages]

  # A `lang` opt (the widget's `data-lang`, threaded from the join payload) nudges the
  # agent to reply in the site's declared language from its very first turn, before
  # there's enough of the visitor's own text to infer it. Injected as a system message
  # (invisible in `visible_history`, since system/tool roles are filtered there) and
  # only on the session's first-ever turn (`prior_messages` holding just the base
  # system prompt) - later turns already have enough of the visitor's own language to
  # go on, and re-injecting every turn would fight a conversation that has since
  # switched languages.
  defp maybe_add_lang_hint(base, opts, prior_messages) do
    with lang when is_binary(lang) and lang != "" <- Keyword.get(opts, :lang),
         true <- first_turn?(prior_messages) do
      base ++
        [
          Message.system(
            "The site embedding this chat declares its language as \"#{lang}\" - reply in that language unless the visitor writes in a different one."
          )
        ]
    else
      _ -> base
    end
  end

  # Truncate back to just before the last user message.
  defp drop_last_turn(messages) do
    case messages
         |> Enum.with_index()
         |> Enum.filter(&(elem(&1, 0)["role"] == "user"))
         |> List.last() do
      {_msg, idx} -> Enum.take(messages, idx)
      nil -> messages
    end
  end

  # Resolve the bound agent (falling back to the default), with this session's model
  # override applied, if any. Used by every handler that runs a live turn (`:chat`,
  # `:heartbeat`, `:aside`) - `:learn`'s background review deliberately calls
  # `Config.get_agent/1` directly instead, so a session's ephemeral model experiment
  # never changes what model teaches the agent long-term.
  defp resolve_agent(state) do
    case Config.get_agent(state.agent_name) || Config.default_agent() do
      nil -> nil
      agent -> apply_model_override(agent, state.model_override)
    end
  end

  defp apply_model_override(agent, nil), do: agent
  defp apply_model_override(agent, model_name), do: %{agent | model: model_name}

  defp model_id(agent_name, override) do
    with name when is_binary(name) <- agent_name,
         %{} = agent <- Config.get_agent(name),
         agent = apply_model_override(agent, override),
         %{model: model} <- Config.model_for_agent(agent) do
      model
    else
      _ -> nil
    end
  end
end
