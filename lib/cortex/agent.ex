defmodule Cortex.Agent do
  @moduledoc """
  High-level facade for running agents — the public API used by the CLI, the
  OpenAI-compatible HTTP server, the WebSocket channel and the Telegram gateway.
  """

  alias Cortex.Agent.Runtime
  alias Cortex.Agent.Session
  alias Cortex.Agent.SessionSupervisor
  alias Cortex.Config

  @doc """
  Run a single prompt against an agent with no persistent session.
  `agent_name` may be nil to use the default agent.
  """
  def oneshot(agent_name, prompt, opts \\ []) do
    case resolve_agent(agent_name) do
      {:ok, agent} -> Runtime.converse(agent, prompt, opts)
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
  Ask a one-off side question on a session's live context without recording it —
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

  defp resolve_agent(nil) do
    case Config.default_agent() do
      nil -> {:error, :no_agent_configured}
      agent -> {:ok, agent}
    end
  end

  defp resolve_agent(name) do
    case Config.get_agent(name) do
      nil -> {:error, {:unknown_agent, name}}
      agent -> {:ok, agent}
    end
  end
end
