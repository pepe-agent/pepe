defmodule Pepe.Agent.Runtime do
  @moduledoc """
  The agent conversation loop - the heart of Pepe.

  Given an agent, a model connection and a list of messages, it calls the model,
  executes any requested tool calls, feeds the results back, and repeats until
  the model produces a final answer (or hits `max_iterations`).

  Emits lifecycle events through an optional `:on_event` callback:

      {:assistant_delta, text}      # streamed text fragment (streaming only)
      {:assistant, text}            # a full assistant turn
      {:tool_call, name, args}      # the agent decided to call a tool
      {:tool_denied, name, reason}  # the user refused to authorize the tool (reason may be nil)
      {:tool_result, name, output}  # the tool returned
      {:done, content}              # final answer
      {:error, reason}

  Risky tool calls are gated through `Pepe.Permissions`: pass an `:authorize`
  callback (and the surface gets a `:session_key`) and the loop asks the user
  before running them. With no `:authorize`, tools run freely.
  """

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM
  alias Pepe.LLM.Message
  alias Pepe.Tools

  @stopped_message "(stopped: max iterations reached)"
  @out_of_turns_nudge "You're out of turns for this task. Do not call any more tools - " <>
                        "reply now with your best summary of what you found or accomplished " <>
                        "so far, and what (if anything) is left unfinished."

  @type opts :: [
          model: Model.t(),
          on_event: (term() -> any()),
          stream: boolean(),
          cwd: String.t(),
          session_key: String.t() | nil,
          source: String.t() | nil,
          authorize: (String.t(), term(), map() -> Pepe.Permissions.decision()) | nil
        ]

  @doc """
  Run the loop over an existing message list. Returns
  `{:ok, final_content, all_messages}` or `{:error, reason}`.
  """
  @spec run(Agent.t(), [map()], opts()) ::
          {:ok, String.t(), [map()]} | {:error, term()}
  def run(%Agent{} = agent, messages, opts \\ []) do
    own_trace? =
      Pepe.Trace.start(agent.name, opts[:session_key], last_user_text(messages), opts[:source]) ==
        :started

    result = do_run(agent, messages, opts)
    if own_trace?, do: Pepe.Trace.finish(result)
    result
  end

  # The most recent user message text, to label a trace with what triggered it.
  defp last_user_text(messages) do
    Enum.reduce(messages, nil, fn m, acc ->
      m = Map.new(m, fn {k, v} -> {to_string(k), v} end)
      if m["role"] == "user" and is_binary(m["content"]), do: m["content"], else: acc
    end)
  end

  defp do_run(%Agent{} = agent, messages, opts) do
    # The failover chain: an explicit :model wins (single-entry chain); otherwise the
    # agent's model followed by that model's `fallbacks`. Transient errors advance.
    chain =
      case opts[:model] do
        nil -> Config.model_chain_for_agent(agent)
        model -> [model]
      end

    cond do
      chain == [] ->
        {:error, :no_model_configured}

      # A model marked `require_redaction` refuses to run unless the agent redacts.
      Enum.any?(chain, & &1.require_redaction) and not Pepe.Hooks.any?(agent) ->
        {:error, :redaction_required}

      # A company at its monthly spend cap stops here (no new model calls).
      Pepe.Usage.over_budget?(Pepe.Company.of(agent.name)) ->
        {:error, :budget_exceeded}

      true ->
        run_chain(agent, chain, messages, opts)
    end
  end

  defp run_chain(agent, chain, messages, opts) do
    specs = Tools.specs(agent.tools)

    ctx = %{
      cwd: opts[:cwd] || File.cwd!(),
      agent: agent,
      session_key: opts[:session_key],
      authorize: opts[:authorize],
      # When true (autonomous consolidation), file writes are staged for review
      # instead of applied - see Pepe.Approval.
      review: opts[:review] == true,
      # The agent-to-agent call chain, for routing loop/hop guards (send_to_agent).
      agent_chain: opts[:agent_chain]
    }

    loop(agent, chain, messages, specs, ctx, opts, agent.max_iterations)
  end

  @doc """
  Convenience: start a fresh conversation from a single user prompt.
  Returns `{:ok, final_content, all_messages}`.
  """
  @spec converse(Agent.t(), String.t(), opts()) :: {:ok, String.t(), [map()]} | {:error, term()}
  def converse(%Agent{} = agent, prompt, opts \\ []) do
    messages = [Message.system(Pepe.Agent.Workspace.system_prompt(agent)), Message.user(prompt)]
    run(agent, messages, opts)
  end

  # Out of turns: rather than a bare hard stop, spend one last call with no
  # tools offered (so the model can't ask for yet another turn) forcing it to
  # summarize whatever it found/did instead of leaving the user with nothing.
  defp loop(agent, chain, messages, _specs, ctx, opts, 0) do
    nudge = Message.user(@out_of_turns_nudge)
    chat_opts = [temperature: agent.temperature]

    case chat_with_failover(chain, messages ++ [nudge], chat_opts, ctx, opts) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        emit(opts, {:assistant, content})
        emit(opts, {:done, content})
        {:ok, content, messages ++ [nudge, Message.assistant(content)]}

      {:error, reason} ->
        emit(opts, {:error, reason})
        {:error, reason}

      _ ->
        emit(opts, {:done, @stopped_message})
        {:ok, @stopped_message, messages}
    end
  end

  defp loop(agent, chain, messages, specs, ctx, opts, iterations_left) do
    chat_opts = [tools: specs, temperature: agent.temperature]

    # Fold any /inline messages the caller injected mid-turn (`Session.inline/2`) into
    # the history as user turns before this iteration's model call, so the agent reacts
    # to them right away instead of only after the turn finishes.
    messages = drain_steer(messages, opts)

    # Keep the running history under the model's context window so long conversations
    # don't fail once they outgrow it (a no-op until it's actually large).
    messages = Pepe.Agent.Compaction.compact(messages, hd(chain))

    result = chat_with_failover(chain, messages, chat_opts, ctx, opts)

    case result do
      {:ok, %{tool_calls: tool_calls} = res} when tool_calls != [] ->
        if res.content && res.content != "", do: emit(opts, {:assistant, res.content})

        assistant_msg = Message.assistant_tool_calls(res.content, tool_calls)
        tool_msgs = Enum.map(tool_calls, &run_tool(&1, ctx, opts))

        new_messages = messages ++ [assistant_msg] ++ tool_msgs

        # Stuck-loop guard: if the model keeps issuing the exact same tool call, it's
        # spinning with no progress (a failing command it won't stop retrying). Drop to
        # the terminal branch, which strips tools and makes it summarize instead of
        # looping to max_iterations.
        if stuck?(tool_calls, messages) do
          loop(agent, chain, new_messages, specs, ctx, opts, 0)
        else
          loop(agent, chain, new_messages, specs, ctx, opts, iterations_left - 1)
        end

      {:ok, %{content: content}} ->
        content = content || ""
        emit(opts, {:assistant, content})
        emit(opts, {:done, content})
        {:ok, content, messages ++ [Message.assistant(content)]}

      {:error, reason} ->
        emit(opts, {:error, reason})
        {:error, reason}
    end
  end

  # Pull every pending `{:steer, text}` off the run task's mailbox (non-blocking) and
  # append each as a user message. Emits a lifecycle event so a live surface can show
  # the injected line was picked up.
  defp drain_steer(messages, opts) do
    receive do
      {:steer, text} ->
        emit(opts, {:inline, text})
        drain_steer(messages ++ [Message.user(text)], opts)
    after
      0 -> messages
    end
  end

  # The same tool call (name + arguments) issued this many times means the agent is
  # stuck repeating it with no progress.
  @stuck_repeats 3

  @doc false
  # True when any of `tool_calls` has already been issued identically enough times in
  # `prior` that this one tips it over the repeat threshold.
  def stuck?(tool_calls, prior) do
    counts = tool_call_signatures(prior)
    Enum.any?(tool_calls, fn c -> Map.get(counts, signature(c), 0) >= @stuck_repeats - 1 end)
  end

  defp tool_call_signatures(messages) do
    for %{"role" => "assistant", "tool_calls" => calls} <- messages,
        is_list(calls),
        c <- calls,
        reduce: %{} do
      acc -> Map.update(acc, signature(c), 1, &(&1 + 1))
    end
  end

  defp signature(%{"function" => %{"name" => name, "arguments" => args}}), do: {name, args}
  defp signature(_), do: :unknown

  # Try each model in the chain; advance ONLY on transient failures (rate limit,
  # server error, network) - auth/request errors fail fast (a bad key on model B
  # won't be fixed by model C's endpoint, and 4xx would just repeat).
  defp chat_with_failover([model | rest], messages, chat_opts, ctx, opts) do
    result =
      if opts[:stream] do
        on_delta = fn text -> emit(opts, {:assistant_delta, text}) end
        LLM.stream_chat(model, messages, on_delta, chat_opts)
      else
        LLM.chat(model, messages, chat_opts)
      end

    case result do
      {:error, reason} = error ->
        if rest != [] and transient?(reason) do
          require Logger

          Logger.warning("[llm] #{model.name} failed transiently, failing over: #{inspect(reason)}")

          emit(opts, {:failover, model.name, hd(rest).name})
          chat_with_failover(rest, messages, chat_opts, ctx, opts)
        else
          error
        end

      {:ok, res} = ok ->
        record_usage(ctx, model, res[:usage], opts)
        ok
    end
  end

  # Meter tokens for billing, attributed to the agent's company (the model call is
  # the single choke point every surface flows through). Best-effort: a metering
  # failure must never break the conversation.
  defp record_usage(%{agent: %{name: name}}, model, usage, opts) when is_map(usage) do
    Pepe.Usage.record(name, model.name, usage)
    emit(opts, {:usage, model.name, usage})
  rescue
    _ -> :ok
  end

  defp record_usage(_ctx, _model, _usage, _opts), do: :ok

  defp transient?(%Req.TransportError{}), do: true
  defp transient?(%{reason: :timeout}), do: true

  defp transient?({:http_error, status, _}) when status in [408, 429, 500, 502, 503, 504, 529],
    do: true

  defp transient?(_), do: false

  defp run_tool(
         %{"id" => id, "function" => %{"name" => name, "arguments" => raw}} = call,
         ctx,
         opts
       ) do
    emit(opts, {:tool_call, name, raw})

    output =
      cond do
        ctx[:review] and stageable?(name) ->
          stage_for_review(name, call, ctx)

        true ->
          case Pepe.Permissions.gate(name, raw, ctx) do
            :allow ->
              Tools.execute(call, ctx)

            :deny ->
              emit(opts, {:tool_denied, name, nil})
              Pepe.Permissions.denied_message(name)

            {:deny, reason} ->
              emit(opts, {:tool_denied, name, reason})
              Pepe.Permissions.denied_message(name, reason)
          end
      end

    emit(opts, {:tool_result, name, output})
    Message.tool_result(id, name, output)
  end

  # Mutating file tools whose autonomous use we stage for review rather than apply.
  @stageable ~w(write_file edit_file move_file)
  defp stageable?(name), do: name in @stageable

  defp stage_for_review(name, call, ctx) do
    agent = (ctx[:agent] && ctx.agent.name) || "unknown"
    {:ok, id, _} = Pepe.Approval.stage(agent, call)
    "Staged this #{name} for review (id #{id}); it will be applied only after you approve it with `pepe review approve #{id}`."
  end

  defp emit(opts, event) do
    Pepe.Trace.event(event)

    case opts[:on_event] do
      fun when is_function(fun, 1) -> fun.(event)
      _ -> :ok
    end
  end
end
