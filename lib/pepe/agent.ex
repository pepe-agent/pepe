defmodule Pepe.Agent do
  @moduledoc """
  High-level facade for running agents - the public API used by the CLI, the
  OpenAI-compatible HTTP server, the WebSocket channel and the Telegram gateway.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config

  @doc """
  Run a single prompt against an agent with no persistent session.
  `agent_name` may be nil to use the default agent. `opts[:model]`, when given,
  overrides which model connection this one call uses - in memory only, nothing
  is persisted or touches the agent's own config (see `Pepe.Eval`'s `--models`).
  """
  def oneshot(agent_name, prompt, opts \\ []) do
    case resolve(agent_name) do
      {:ok, agent} ->
        {model, opts} = Keyword.pop(opts, :model)
        agent = if model, do: %{agent | model: model}, else: agent
        converse_with_hooks(agent, prompt, opts)

      error ->
        error
    end
  end

  @doc """
  Resolve an agent name (nil for the default agent) to its config, without running
  anything. Exposed for callers - the CLI, the dashboard, the WebSocket channel, the
  OpenAI-compatible controller - that need to inspect the agent (e.g. `Pepe.Hooks.stream?/1`)
  *before* deciding how to call `oneshot/3`/`chat/4`, not just to run one.
  """
  @spec resolve(String.t() | nil) :: {:ok, Pepe.Config.Agent.t()} | {:error, term()}
  def resolve(nil) do
    case Config.default_agent() do
      nil -> {:error, :no_agent_configured}
      agent -> {:ok, agent}
    end
  end

  def resolve(name) do
    case Config.get_agent(name) do
      nil -> {:error, {:unknown_agent, name}}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Should this agent name (nil for the default agent) stream live `:assistant_delta`
  events? Delegates to `Pepe.Hooks.stream?/1` once the name is resolved. An unresolvable
  name defaults to `true` (stream) - the actual call this feeds into (`oneshot/3`,
  `chat/4`, ...) re-resolves the agent itself and surfaces its own `{:error, ...}`, so this
  only ever decides how a call that's *going to happen* gets rendered, never whether it's
  allowed to.
  """
  @spec stream_for?(String.t() | nil) :: boolean()
  def stream_for?(agent_name) do
    case resolve(agent_name) do
      {:ok, agent} -> Pepe.Hooks.stream?(agent)
      _ -> true
    end
  end

  # A one-shot call has no persisted session (so no carried-over reversible-map entries
  # from an earlier turn), but still owes an agent's `hooks` the same treatment
  # `Pepe.Agent.Session` gives every session-backed turn - the built-in PII/LLM/HTTP/Presidio
  # redaction, and any plugin content-mutation hook, ran on every other surface but this one
  # until now: `Runtime.converse/3` alone never touches `Pepe.Hooks`. `:tool_result`
  # redaction still works mid-run - `Pepe.Hooks.start_map/1` seeds this process's
  # accumulator before the run, and `Pepe.Tools.execute/2` grows it as tool calls happen,
  # same as a session's spawned task. The caller decides whether to stream
  # (`Pepe.Hooks.stream?/1`) - when it does, a live delta is always the model's raw,
  # un-hooked text, since `:outbound` only runs once the full reply is in hand below.
  defp converse_with_hooks(agent, prompt, opts) do
    {redacted, entries} = Pepe.Hooks.transform(:inbound, prompt, agent, %{"map" => []})
    Pepe.Hooks.start_map(entries)

    case Runtime.converse(agent, redacted, opts) do
      {:ok, reply, messages} ->
        map = Pepe.Hooks.take_map()
        {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
        {:ok, Pepe.Hooks.restore(shown, map), messages}

      other ->
        Pepe.Hooks.take_map()
        other
    end
  end

  @doc """
  Run a memory-housekeeping pass: the agent re-reads and consolidates its own standing
  memory and skills (no conversation). Returns `{:ok, summary, messages}`.
  """
  def consolidate(agent_name) do
    case resolve(agent_name) do
      {:ok, agent} -> Pepe.Agent.Reflect.consolidate(agent)
      error -> error
    end
  end

  @doc """
  Send a message within a persistent, keyed session (creating it on first use).
  """
  @spec chat(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def chat(session_key, agent_name, text, opts \\ []) do
    case SessionSupervisor.ensure(session_key, agent_name) do
      {:ok, _pid} -> Session.chat(session_key, text, opts)
      error -> error
    end
  end

  @doc """
  Ask a one-off side question on a session's live context without recording it -
  the exchange does not affect future turns. Creates the session if needed.
  """
  @spec aside(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def aside(session_key, agent_name, text, opts \\ []) do
    case SessionSupervisor.ensure(session_key, agent_name) do
      {:ok, _pid} -> Session.aside(session_key, text, opts)
      error -> error
    end
  end
end
