defmodule Pepe.ApiScope do
  @moduledoc """
  Resolve and authorize agents against an API-token scope - shared by the HTTP
  controller and the WebSocket channel so both enforce tenancy identically.

  A scope is `:unrestricted` (the API is open because no tokens are configured) or
  `%{project: c, agent: a}` (either may be nil). See `Pepe.ApiToken`.

  It also answers what the token may *do* - run agents, read usage, how much of the money
  it may see - so both surfaces read the same permission from the same place instead of
  each deciding what a missing field means.
  """

  alias Pepe.Project
  alias Pepe.Config

  @doc """
  Resolve a requested agent name to an in-scope `%Config.Agent{}`, or `nil` when it's
  out of scope. An empty name yields the scope's default agent.

  The open scope is lenient - an unknown name falls back to the default agent (legacy
  behaviour) - while a token scope is strict: an agent-locked token always returns its
  agent, and a project token returns only agents inside it (bare names qualify in),
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

  def authorize_agent(name, %{project: project}) do
    if present?(name),
      do: scoped_agent(name, Config.resolve_scope(project)),
      else: agent_by_handle(Config.default_agent_for(project))
  end

  @doc "The agents a scope may see and list."
  def visible_agents(:unrestricted), do: Config.agents()
  def visible_agents(%{agent: a}) when is_binary(a), do: List.wrap(Config.get_agent(a))
  def visible_agents(%{project: c}), do: Config.agents_in(c)

  @doc "May this scope also use a bare model connection (open or root scope only)?"
  def root_or_open?(:unrestricted), do: true
  def root_or_open?(%{project: nil, agent: nil}), do: true
  def root_or_open?(_), do: false

  @doc """
  May this scope run agents? True unless the token was explicitly minted read-only - see
  `Pepe.ApiToken`'s moduledoc for why the default falls this way.
  """
  def chat?(:unrestricted), do: true
  def chat?(%{chat: false}), do: false
  def chat?(_), do: true

  @doc "May this scope read `/v1/usage`? Off unless the token was minted for it."
  def usage?(:unrestricted), do: true
  def usage?(%{usage: true}), do: true
  def usage?(_), do: false

  @doc """
  How much of the money this scope may see: `"billable"` (with markup), `"list"` (no
  markup) or `"all"` (adds `cost` and `margin`). Decided by the token, never by the
  request.
  """
  def prices(:unrestricted), do: "all"
  def prices(%{prices: view}), do: Pepe.ApiToken.price_view(view)
  def prices(_), do: "billable"

  @doc "May a run's detail include conversation content (prompt, tool arguments, tool output)?"
  def usage_content?(:unrestricted), do: true
  def usage_content?(%{usage_content: true, usage: true}), do: true
  def usage_content?(_), do: false

  @doc """
  Which projects a scope may read usage for: `:all` for the open/root scope, otherwise the
  one project it is confined to. An agent-locked token is confined further still, by
  `usage_agent/1`.
  """
  def usage_scope(:unrestricted), do: :all
  def usage_scope(%{agent: agent}) when is_binary(agent), do: [Config.resolve_scope(Project.of(agent))]
  def usage_scope(%{project: project}) when is_binary(project), do: [Config.resolve_scope(project)]
  def usage_scope(_), do: :all

  @doc "The single agent a scope's usage reads are pinned to, or `nil` when it may see a whole project."
  def usage_agent(%{agent: agent}) when is_binary(agent), do: agent
  def usage_agent(_), do: nil

  # Resolve a name to an agent only if it lives in `project` (bare names qualify in).
  defp scoped_agent(name, project) do
    handle = if Project.of(name) == project, do: name, else: Project.handle(project, name)
    if Project.of(handle) == project, do: Config.get_agent(handle), else: nil
  end

  defp agent_by_handle(nil), do: nil
  defp agent_by_handle(handle), do: Config.get_agent(handle)

  defp present?(v), do: is_binary(v) and v != ""
end
