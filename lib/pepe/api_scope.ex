defmodule Pepe.ApiScope do
  @moduledoc """
  Resolve and authorize agents against an API-token scope - shared by the HTTP
  controller and the WebSocket channel so both enforce tenancy identically.

  A scope is `:unrestricted` (the API is open because no tokens are configured) or
  `%{company: c, agent: a}` (either may be nil). See `Pepe.ApiToken`.
  """

  alias Pepe.Company
  alias Pepe.Config

  @doc """
  Resolve a requested agent name to an in-scope `%Config.Agent{}`, or `nil` when it's
  out of scope. An empty name yields the scope's default agent.

  The open scope is lenient - an unknown name falls back to the default agent (legacy
  behaviour) - while a token scope is strict: an agent-locked token always returns its
  agent, and a company token returns only agents inside it (bare names qualify in),
  `nil` otherwise. A name that is a bare model connection (not an agent) returns `nil`
  so callers that support model pass-through can handle it.
  """
  def authorize_agent(name, :unrestricted) do
    cond do
      not present?(name) -> Config.default_agent()
      agent = Config.get_agent(name) -> agent
      Config.get_model(name) -> nil
      true -> Config.default_agent()
    end
  end

  def authorize_agent(_name, %{agent: agent}) when is_binary(agent), do: Config.get_agent(agent)

  def authorize_agent(name, %{company: company}) do
    if present?(name),
      do: scoped_agent(name, company),
      else: agent_by_handle(Config.default_agent_for(company))
  end

  @doc "The agents a scope may see and list."
  def visible_agents(:unrestricted), do: Config.agents()
  def visible_agents(%{agent: a}) when is_binary(a), do: List.wrap(Config.get_agent(a))
  def visible_agents(%{company: c}), do: Config.agents_in(c)

  @doc "May this scope also use a bare model connection (open or root scope only)?"
  def root_or_open?(:unrestricted), do: true
  def root_or_open?(%{company: nil, agent: nil}), do: true
  def root_or_open?(_), do: false

  # Resolve a name to an agent only if it lives in `company` (bare names qualify in).
  defp scoped_agent(name, company) do
    handle = if Company.of(name) == company, do: name, else: Company.handle(company, name)
    if Company.of(handle) == company, do: Config.get_agent(handle), else: nil
  end

  defp agent_by_handle(nil), do: nil
  defp agent_by_handle(handle), do: Config.get_agent(handle)

  defp present?(v), do: is_binary(v) and v != ""
end
