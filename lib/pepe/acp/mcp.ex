defmodule Pepe.ACP.Mcp do
  @moduledoc """
  MCP servers an editor hands over for one ACP session.

  An editor's own settings can list MCP servers ("the tools I want my agent to have while
  I work in this project") and send them with `session/new`. This module makes them
  available to that session's turns and to nothing else.

  ## The shape of it

    * **Scoped.** The servers belong to the session that attached them. Their tools are
      offered only on that session's turns (`ctx[:mcp_scope]`, set by the ACP connection),
      never written to `config.json`, never visible to another session, agent or surface,
      and stopped when the session or the connection ends.
    * **Namespaced apart from configured servers.** A tool is published as
      `mcp__editor_<server>__<tool>`, and a server whose namespace would equal a configured
      server's name is refused. Standing `auto_approve` grants match a tool by name, so an
      editor cannot speak as one of the operator's own servers and inherit its trust.
    * **Inside the same permission model.** These are ordinary MCP tools to
      `Pepe.Permissions`: they are not in the always-safe set, so each call is gated (asked
      through `session/request_permission`) unless the agent's own `auto_approve` covers
      it, and their results are outside content, so a run that used one is tainted exactly
      as it would be by a configured MCP tool.
    * **Literal.** Values from the editor are never interpolated (`${VAR}`, `exec:`, `file:`
      mean nothing here), and no stored OAuth token is ever sent to them. See
      `Pepe.ACP.Mcp.Descriptor`.
    * **Forgiving.** A server that will not start is reported to the person in the editor
      and the session carries on without it. Nothing an editor sends can fail `session/new`
      except a malformed `mcpServers` field itself.

  ## Entry points

  `attach/3` is the one call the ACP connection makes for `session/new` (and, for a
  session it resumes or loads, again with that request's servers). `specs/1`, `call/3` and
  `notices/1` are what a turn uses.
  """

  alias Pepe.ACP.Mcp.Manager

  @prefix "mcp__editor_"

  # How long the first turn waits for servers still starting. Long enough for a slow `npx`
  # cold start, short enough that a dead server does not stall the conversation.
  @await_ms 20_000

  @doc """
  What `initialize` advertises under `agentCapabilities.mcpCapabilities`: exactly the
  remote transports that work here. (Stdio is required of every agent and is not listed.)
  """
  @spec capabilities() :: map()
  def capabilities, do: %{"http" => true, "sse" => true}

  @doc "Is this the name of a tool an editor-supplied server published?"
  @spec scoped_name?(term()) :: boolean()
  def scoped_name?(name), do: is_binary(name) and String.starts_with?(name, @prefix)

  @doc """
  Attach an editor's `servers` to `session` (a map with `:key` and `:cwd`), replacing any
  attached to it before. Returns `{:ok, %{accepted: [name], rejected: [{name, reason}]}}`
  immediately - servers start in the background - or `{:error, :invalid}` when `servers`
  is not a list. `nil` and `[]` attach nothing.

  Rejections and start failures are not returned as errors: they are kept as notices for
  the person in the editor (`notices/1`), because one bad server must not cost the session.

  The servers live as long as `opts[:owner]` (the calling process by default), which is the
  ACP connection: when it exits, they stop.
  """
  @spec attach(map(), term(), keyword()) :: {:ok, map()} | {:error, :invalid}
  def attach(session, servers, opts \\ [])

  def attach(%{key: key}, servers, _opts) when servers in [nil, []] do
    Manager.detach(key)
    {:ok, %{accepted: [], rejected: []}}
  end

  def attach(%{key: key} = session, servers, opts) when is_list(servers),
    do: Manager.attach(key, opts[:owner] || self(), servers, session[:cwd])

  def attach(_session, _servers, _opts), do: {:error, :invalid}

  @doc "Stop and forget the servers attached to `session` (a scope key)."
  @spec detach(String.t()) :: :ok
  def detach(scope), do: Manager.detach(scope)

  @doc """
  Tool specs for `scope`'s servers that are up, waiting (bounded) for any still starting.
  `[]` for `nil` - which is every surface but ACP - without touching the manager.
  """
  @spec specs(String.t() | nil) :: [map()]
  def specs(nil), do: []

  def specs(scope) do
    _ = Manager.await(scope, @await_ms)
    Manager.specs(scope)
  catch
    :exit, _ -> []
  end

  @doc """
  Sentences for the person in the editor about servers that were refused or failed to
  start, each returned once. Waits (bounded) for servers still starting, like `specs/1`.
  """
  @spec notices(String.t() | nil) :: [String.t()]
  def notices(nil), do: []

  def notices(scope) do
    _ = Manager.await(scope, @await_ms)
    Manager.notices(scope)
  catch
    :exit, _ -> []
  end

  @doc """
  Call a tool an editor-supplied server published, on behalf of `scope`'s turn. Only that
  scope's own servers are ever consulted. A server that has died since it started is started
  once more before giving up.
  """
  @spec call(String.t() | nil, String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def call(nil, _name, _args), do: {:error, "there is no editor MCP server in this context"}

  def call(scope, name, args) do
    case Manager.lookup(scope, name) do
      {:ok, target} -> run(target, args, true)
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, "the editor MCP servers are not available"}
  end

  defp run(%{key: key, tool: tool, spec: spec, sup: sup} = target, args, retry?) do
    case Pepe.MCP.call_running(key, tool, args) do
      {:error, reason} when reason in [:not_running, :server_down] and retry? ->
        case Pepe.MCP.start_spec(key, spec, sup) do
          {:ok, _pid, _module} -> run(target, args, false)
          {:error, {:already_started, _pid}} -> run(target, args, false)
          {:error, _reason} -> {:error, "the editor's MCP server is no longer running and could not be restarted"}
        end

      other ->
        other
    end
  end
end
