defmodule Cortex.Agent.Runtime do
  @moduledoc """
  The agent conversation loop — the heart of Cortex.

  Given an agent, a model connection and a list of messages, it calls the model,
  executes any requested tool calls, feeds the results back, and repeats until
  the model produces a final answer (or hits `max_iterations`).

  Emits lifecycle events through an optional `:on_event` callback:

      {:assistant_delta, text}      # streamed text fragment (streaming only)
      {:assistant, text}            # a full assistant turn
      {:tool_call, name, args}      # the agent decided to call a tool
      {:tool_denied, name}          # the user refused to authorize the tool
      {:tool_result, name, output}  # the tool returned
      {:done, content}              # final answer
      {:error, reason}

  Risky tool calls are gated through `Cortex.Permissions`: pass an `:authorize`
  callback (and the surface gets a `:session_key`) and the loop asks the user
  before running them. With no `:authorize`, tools run freely.
  """

  alias Cortex.Config
  alias Cortex.Config.Agent
  alias Cortex.Config.Model
  alias Cortex.LLM
  alias Cortex.LLM.Message
  alias Cortex.Tools

  @type opts :: [
          model: Model.t(),
          on_event: (term() -> any()),
          stream: boolean(),
          cwd: String.t(),
          session_key: String.t() | nil,
          authorize: (String.t(), term(), map() -> Cortex.Permissions.decision()) | nil
        ]

  @doc """
  Run the loop over an existing message list. Returns
  `{:ok, final_content, all_messages}` or `{:error, reason}`.
  """
  @spec run(Agent.t(), [map()], opts()) ::
          {:ok, String.t(), [map()]} | {:error, term()}
  def run(%Agent{} = agent, messages, opts \\ []) do
    # The failover chain: an explicit :model wins (single-entry chain); otherwise the
    # agent's model followed by that model's `fallbacks`. Transient errors advance.
    chain =
      case opts[:model] do
        nil -> Config.model_chain_for_agent(agent)
        model -> [model]
      end

    if chain == [] do
      {:error, :no_model_configured}
    else
      specs = Tools.specs(agent.tools)

      ctx = %{
        cwd: opts[:cwd] || File.cwd!(),
        agent: agent,
        session_key: opts[:session_key],
        authorize: opts[:authorize],
        # The agent-to-agent call chain, for routing loop/hop guards (send_to_agent).
        agent_chain: opts[:agent_chain]
      }

      loop(agent, chain, messages, specs, ctx, opts, agent.max_iterations)
    end
  end

  @doc """
  Convenience: start a fresh conversation from a single user prompt.
  Returns `{:ok, final_content, all_messages}`.
  """
  def converse(%Agent{} = agent, prompt, opts \\ []) do
    messages = [Message.system(Cortex.Agent.Workspace.system_prompt(agent)), Message.user(prompt)]
    run(agent, messages, opts)
  end

  defp loop(_agent, _chain, messages, _specs, _ctx, opts, 0) do
    emit(opts, {:done, "(stopped: max iterations reached)"})
    {:ok, "(stopped: max iterations reached)", messages}
  end

  defp loop(agent, chain, messages, specs, ctx, opts, iterations_left) do
    chat_opts = [tools: specs, temperature: agent.temperature]

    result = chat_with_failover(chain, messages, chat_opts, ctx, opts)

    case result do
      {:ok, %{tool_calls: tool_calls} = res} when tool_calls != [] ->
        if res.content && res.content != "", do: emit(opts, {:assistant, res.content})

        assistant_msg = Message.assistant_tool_calls(res.content, tool_calls)
        tool_msgs = Enum.map(tool_calls, &run_tool(&1, ctx, opts))

        new_messages = messages ++ [assistant_msg] ++ tool_msgs
        loop(agent, chain, new_messages, specs, ctx, opts, iterations_left - 1)

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

  # Try each model in the chain; advance ONLY on transient failures (rate limit,
  # server error, network) — auth/request errors fail fast (a bad key on model B
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

          Logger.warning(
            "[llm] #{model.name} failed transiently, failing over: #{inspect(reason)}"
          )

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
    Cortex.Usage.record(name, model.name, usage)
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
      case Cortex.Permissions.gate(name, raw, ctx) do
        :allow ->
          Tools.execute(call, ctx)

        :deny ->
          emit(opts, {:tool_denied, name})
          Cortex.Permissions.denied_message(name)
      end

    emit(opts, {:tool_result, name, output})
    Message.tool_result(id, name, output)
  end

  defp emit(opts, event) do
    case opts[:on_event] do
      fun when is_function(fun, 1) -> fun.(event)
      _ -> :ok
    end
  end
end
