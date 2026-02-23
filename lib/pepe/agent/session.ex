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
  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.LLM.Message

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

  @doc "Drop the last user turn (and its responses) from the history."
  @spec undo(term()) :: :ok
  def undo(key), do: GenServer.call(via(key), :undo)

  @doc "Cancel the in-flight run for this session, if any."
  @spec stop(term()) :: :ok | {:error, :not_running}
  def stop(key), do: GenServer.call(via(key), :stop)

  @doc "Run the memory/skill review now over this session (the `/learn` trigger)."
  @spec learn(term()) :: :ok | {:error, :no_agent}
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

  # Recent turns kept verbatim when compacting.
  @keep_recent 4

  ###
  ### server
  ###

  alias Pepe.Agent.SessionPersistence

  @impl true
  def init(opts) do
    key = Keyword.fetch!(opts, :key)
    default_agent = Keyword.get(opts, :agent_name) || Config.default_agent_name()

    state =
      case persist?() && SessionPersistence.load(key) do
        {:ok, name, messages} ->
          %{key: key, agent_name: name || default_agent, messages: messages, running: nil}

        _ ->
          %{
            key: key,
            agent_name: default_agent,
            messages: init_messages(default_agent),
            running: nil,
            idle_ref: nil
          }
      end

    # `learn_allowed` gates the memory/skill review for THIS conversation. The
    # surface sets it per turn (Telegram computes it from the bot's `trainers`
    # allowlist + the sender), so a client's chat never becomes memory. Defaults to
    # true (an owner console/API conversation learns unless told otherwise).
    #
    # `ttl_ms` evicts the session after that much inactivity (nil = never, the
    # default). `ephemeral` skips persistence and clears on eviction - used by
    # customer-facing channels so support conversations don't accumulate.
    state =
      state
      |> Map.put_new(:idle_ref, nil)
      |> Map.put_new(:learn_allowed, true)
      |> Map.merge(%{
        ttl_ms: Keyword.get(opts, :ttl_ms),
        ephemeral: Keyword.get(opts, :ephemeral, false),
        reset_pending: false,
        ttl_ref: nil,
        # Reversible redaction map (pseudonym -> real) accumulated by inbound hooks and
        # applied to outbound replies. Lives only in this process; cleared on reset.
        pii_map: []
      })

    {:ok, arm_ttl(state)}
  end

  # Sessions are only persisted in long-running surfaces (serve/gateway), so local
  # `run`/`tui` and tests don't write files.
  defp persist?, do: Application.get_env(:pepe, :persist_sessions, false)

  defp persist(state) do
    if persist?() and not Map.get(state, :ephemeral, false),
      do: SessionPersistence.save(state.key, state.agent_name, state.messages)

    state
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
  def handle_call({:chat, _text, _opts}, _from, %{running: %{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:chat, text, opts}, from, state) do
    # Resolve the agent fresh each turn (fall back to the default if it was renamed),
    # so tools/model changes apply live without breaking the session.
    case Config.get_agent(state.agent_name) || Config.default_agent() do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        # Tag the run with this session's key so `:session` approvals are scoped to it.
        opts = Keyword.put(opts, :session_key, state.key)
        # Whether this conversation may feed the memory/skill review (set by the surface).
        state = %{state | learn_allowed: Keyword.get(opts, :learn, state.learn_allowed)}
        # A new message cancels any pending idle review and re-arms the TTL.
        state = state |> cancel_idle() |> arm_ttl()
        # Run off-process so the session stays responsive (e.g. to `/stop`). The raw
        # user text and the reversible map go in; the task redacts (inbound hooks)
        # before the model sees anything and restores the reply on the way out.
        base = ensure_system(state.messages, agent)
        {pid, ref} = spawn_run(agent, base, text, state.pii_map, opts)
        {:noreply, %{state | running: %{task: pid, ref: ref, from: from}}}
    end
  end

  def handle_call(:stop, _from, %{running: %{}} = state) do
    {:reply, :ok, cancel_running(state, {:error, :stopped})}
  end

  def handle_call(:stop, _from, state), do: {:reply, {:error, :not_running}, state}

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

  # Skip a pulse outright while a normal turn is in flight - never collide with it.
  def handle_call(:heartbeat, _from, %{running: %{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:heartbeat, _from, state) do
    case Config.get_agent(state.agent_name) || Config.default_agent() do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        prompt = Pepe.Heartbeat.build_prompt(state.key, agent.name)
        messages = ensure_system(state.messages, agent) ++ [Message.user(prompt)]
        opts = [session_key: state.key]

        case Runtime.run(agent, messages, opts) do
          {:ok, reply, _all} ->
            if Pepe.Heartbeat.silent?(reply) do
              {:reply, :silent, state}
            else
              # Only the agent's own message joins the visible history - the
              # internal pulse prompt stays invisible, like a cron/system trigger.
              new_state = %{state | messages: state.messages ++ [Message.assistant(reply)]}
              {:reply, {:ok, reply}, persist(new_state)}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:aside, text, opts}, _from, state) do
    case Config.get_agent(state.agent_name) || Config.default_agent() do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        messages = ensure_system(state.messages, agent) ++ [Message.user(text)]
        opts = Keyword.put(opts, :session_key, state.key)

        # Reply from the run but keep `state` untouched, so the aside is ephemeral.
        case Runtime.run(agent, messages, opts) do
          {:ok, reply, _all} -> {:reply, {:ok, reply}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    # A fresh conversation cancels any in-flight run (so a stuck one can't leave the
    # session wedged on `:busy`) and forgets "allow for this session" grants.
    Pepe.Permissions.SessionStore.clear(state.key)
    state = cancel_running(state, {:error, :stopped})
    {:reply, :ok, persist(%{state | messages: init_messages(state.agent_name), pii_map: []})}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call({:set_agent, agent_name}, _from, state) do
    {:reply, :ok, persist(%{state | agent_name: agent_name, messages: init_messages(agent_name)})}
  end

  def handle_call(:undo, _from, state) do
    {:reply, :ok, persist(%{state | messages: drop_last_turn(state.messages)})}
  end

  def handle_call(:status, _from, state) do
    turns = Enum.count(state.messages, &(&1["role"] == "user"))
    {:reply, %{agent: state.agent_name, model: model_id(state.agent_name), turns: turns}, state}
  end

  def handle_call(:compact, _from, state) do
    case state.agent_name && Config.get_agent(state.agent_name) do
      nil ->
        {:reply, {:error, :no_agent}, state}

      agent ->
        # Review before compacting, while the full detail is still here.
        if state.learn_allowed, do: Pepe.Agent.Reflect.review_async(agent, state.messages)

        case compact_messages(agent, state.messages) do
          {:ok, messages, summary} ->
            {:reply, {:ok, summary}, persist(%{state | messages: messages})}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  # A finished run reports here. Reply to the waiting caller and absorb the new
  # history. A stale `:run_done` (the run was stopped meanwhile) is ignored.
  @impl true
  def handle_info({:run_done, result, agent_name}, %{running: %{from: from, ref: ref}} = state) do
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

          %{
            state
            | agent_name: agent_name,
              messages: messages,
              running: nil,
              reset_pending: false,
              pii_map: pii_map
          }
          |> persist()
          |> maybe_schedule_idle()

        {:error, reason} ->
          GenServer.reply(from, {:error, reason})
          %{state | running: nil}
      end

    {:noreply, state}
  end

  def handle_info({:run_done, _result, _agent_name}, state), do: {:noreply, state}

  # The run task died without reporting (external kill, unexpected exit). Recover the
  # session so it isn't pinned on `:busy`, and unblock the waiting caller.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{running: %{ref: ref, from: from}} = state
      ) do
    GenServer.reply(from, {:error, :stopped})
    {:noreply, %{state | running: nil}}
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
    %{state | running: nil}
  end

  defp cancel_running(state, _reply), do: state

  # Run the loop in an unlinked, monitored process so a crash or a `/stop` kill can't
  # take the session down. It always reports back, turning a raise/exit into `{:error, _}`.
  defp spawn_run(agent, base_messages, text, pii_map, opts) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result =
          try do
            # Inbound hooks redact the user text (and grow the reversible map) before
            # the model - off the GenServer, so an LLM-backed redactor never blocks it.
            {redacted, entries} = Pepe.Hooks.transform(:inbound, text, agent, %{"map" => pii_map})

            case Runtime.run(agent, base_messages ++ [Message.user(redacted)], opts) do
              {:ok, reply, all_messages} ->
                map = pii_map ++ entries
                {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
                {:ok, Pepe.Hooks.restore(shown, map), all_messages, entries}

              other ->
                other
            end
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, "run #{kind}: #{inspect(reason)}"}
          end

        send(parent, {:run_done, result, agent.name})
      end)

    {pid, Process.monitor(pid)}
  end

  # A session started before any agent existed has no system message yet - seed one.
  defp ensure_system([%{"role" => "system"} | _] = messages, _agent), do: messages

  defp ensure_system(messages, agent),
    do: [Message.system(Workspace.system_prompt(agent)) | messages]

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

  defp model_id(agent_name) do
    with name when is_binary(name) <- agent_name,
         %{} = agent <- Config.get_agent(name),
         %{model: model} <- Config.model_for_agent(agent) do
      model
    else
      _ -> nil
    end
  end

  # Summarize everything except the most recent `@keep_recent` turns into one
  # system message; keep the system prompt and the recent turns verbatim.
  defp compact_messages(agent, messages) do
    {system, convo} = Enum.split_with(messages, &(&1["role"] == "system"))

    if length(convo) <= @keep_recent do
      {:ok, messages, "nothing to compact yet"}
    else
      {older, recent} = Enum.split(convo, length(convo) - @keep_recent)

      case summarize(Config.model_for_agent(agent), older) do
        {:ok, summary} ->
          summary_msg = Message.system("Summary of earlier conversation:\n" <> summary)
          {:ok, system ++ [summary_msg | recent], summary}

        error ->
          error
      end
    end
  end

  defp summarize(nil, _messages), do: {:error, :no_model}

  defp summarize(model, messages) do
    transcript = Enum.map_join(messages, "\n", fn m -> "#{m["role"]}: #{m["content"]}" end)

    prompt =
      "Summarize the conversation below concisely, preserving facts, decisions and context needed to continue it. Output only the summary.\n\n" <>
        transcript

    case Pepe.LLM.chat(model, [Message.user(prompt)], max_tokens: 600) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, _} -> {:error, :empty_summary}
      error -> error
    end
  end
end
