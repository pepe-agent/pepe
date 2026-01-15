defmodule Cortex.Agent.Session do
  @moduledoc """
  A live conversation. One GenServer per session key (e.g. `"telegram:12345"` or
  a WebSocket connection id), holding the running message history and the bound
  agent. Concurrency, isolation and crash recovery come for free from OTP.
  """

  use GenServer

  alias Cortex.Agent.Runtime
  alias Cortex.Agent.Workspace
  alias Cortex.Config
  alias Cortex.LLM.Message

  ###
  ### client API
  ###

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: via(key))
  end

  defp via(key), do: {:via, Registry, {Cortex.Agent.Registry, key}}

  @doc "Send a user message; runs the loop and returns `{:ok, reply}`."
  def chat(key, text, opts \\ []) do
    GenServer.call(via(key), {:chat, text, opts}, :infinity)
  end

  @doc "Reset the conversation history (keeps the system prompt)."
  def reset(key), do: GenServer.call(via(key), :reset)

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

  @doc "Return `%{agent:, model:, turns:}` for the session."
  def status(key), do: GenServer.call(via(key), :status)

  @doc "Summarize older turns into one message to free up context."
  @spec compact(term()) :: {:ok, String.t()} | {:error, term()}
  def compact(key), do: GenServer.call(via(key), :compact, :infinity)

  @doc """
  Answer a one-off **side question** against the live context without recording it.

  The question and the reply are run on top of the current history but are *not*
  stored, so they never influence future turns — this powers the Telegram `/btw`
  (a.k.a. `/side`) command. Returns `{:ok, reply}` or `{:error, reason}`.
  """
  @spec aside(term(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def aside(key, text, opts \\ []), do: GenServer.call(via(key), {:aside, text, opts}, :infinity)

  # Recent turns kept verbatim when compacting.
  @keep_recent 4

  ###
  ### server
  ###

  alias Cortex.Agent.SessionPersistence

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
    {:ok, state |> Map.put_new(:idle_ref, nil) |> Map.put_new(:learn_allowed, true)}
  end

  # Sessions are only persisted in long-running surfaces (serve/gateway), so local
  # `run`/`tui` and tests don't write files.
  defp persist?, do: Application.get_env(:cortex, :persist_sessions, false)

  defp persist(state) do
    if persist?(), do: SessionPersistence.save(state.key, state.agent_name, state.messages)
    state
  end

  # Seed a session with the system prompt built from the agent's CURRENT config/soul.
  # Called at session start and on /new (reset), so a fresh session always picks up
  # the latest persona/config — a live session keeps its prompt stable until then.
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
        messages = ensure_system(state.messages, agent) ++ [Message.user(text)]
        # Tag the run with this session's key so `:session` approvals are scoped to it.
        opts = Keyword.put(opts, :session_key, state.key)
        # Whether this conversation may feed the memory/skill review (set by the surface).
        state = %{state | learn_allowed: Keyword.get(opts, :learn, state.learn_allowed)}
        # A new message cancels any pending idle review.
        state = cancel_idle(state)
        # Run off-process so the session stays responsive (e.g. to `/stop`). We hold
        # the caller's `from` and reply once the run reports back via `:run_done`,
        # and monitor the task so a stuck/dead run can't pin the session on `:busy`.
        {pid, ref} = spawn_run(agent, messages, opts)
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
        Cortex.Agent.Reflect.review_async(agent, state.messages)
        {:reply, :ok, cancel_idle(state)}
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
    Cortex.Permissions.SessionStore.clear(state.key)
    state = cancel_running(state, {:error, :stopped})
    {:reply, :ok, persist(%{state | messages: init_messages(state.agent_name)})}
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
        if state.learn_allowed, do: Cortex.Agent.Reflect.review_async(agent, state.messages)

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
        {:ok, reply, all_messages} ->
          GenServer.reply(from, {:ok, reply})

          %{state | agent_name: agent_name, messages: all_messages, running: nil}
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

  # The session went idle after a run — run the memory/skill review if this
  # conversation is allowed to learn, then clear the timer.
  def handle_info(:idle_review, state) do
    with true <- state.learn_allowed,
         agent when not is_nil(agent) <- Config.get_agent(state.agent_name) do
      Cortex.Agent.Reflect.review_async(agent, state.messages)
    end

    {:noreply, %{state | idle_ref: nil}}
  end

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
  defp spawn_run(agent, messages, opts) do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result =
          try do
            Runtime.run(agent, messages, opts)
          rescue
            e -> {:error, Exception.message(e)}
          catch
            kind, reason -> {:error, "run #{kind}: #{inspect(reason)}"}
          end

        send(parent, {:run_done, result, agent.name})
      end)

    {pid, Process.monitor(pid)}
  end

  # A session started before any agent existed has no system message yet — seed one.
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

    case Cortex.LLM.chat(model, [Message.user(prompt)], max_tokens: 600) do
      {:ok, %{content: content}} when is_binary(content) and content != "" -> {:ok, content}
      {:ok, _} -> {:error, :empty_summary}
      error -> error
    end
  end
end
