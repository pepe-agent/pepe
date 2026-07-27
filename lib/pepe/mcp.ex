defmodule Pepe.MCP do
  @moduledoc """
  Facade for MCP (Model Context Protocol) tool servers.

  Configured servers (`Pepe.Config.mcp_servers/0`) are launched **on demand** -
  one `Pepe.MCP.Client` per server, started lazily under a DynamicSupervisor and
  cached in a Registry, so the first agent that uses a server pays the spawn cost and
  the rest reuse it.

  An MCP tool is exposed to agents under the namespaced name
  `mcp__<server>__<tool>`. Because that name goes into an agent's ordinary tool
  allowlist, **scoping is free**: to make an agent read-only against a server you list
  only its read tools (e.g. `mcp__sentry__find_organizations`) and leave out the
  mutating ones (`mcp__sentry__update_issue`). A `mcp__<server>__*` entry means "all
  tools of that server". MCP tools are not in the always-safe set, so each call still
  goes through the permission gate.
  """

  alias Pepe.Config
  alias Pepe.MCP.Client
  alias Pepe.MCP.Transport

  @registry Pepe.MCP.Registry
  @sup Pepe.MCP.DynSup

  @doc "Is this an MCP tool name (`mcp__...`)?"
  def mcp_tool?(name), do: is_binary(name) and String.starts_with?(name, "mcp__")

  @doc """
  Ensure the client for `server` is running, starting it if needed. Returns
  `{:ok, pid, transport_module}` - the module travels with the pid because which one is
  speaking to a given server is decided by its config, not by this module.
  """
  def ensure(server) do
    case Registry.lookup(@registry, server) do
      [{pid, module}] -> {:ok, pid, module}
      [] -> start(server)
    end
  end

  @doc """
  Stop the running client for `server`, if any - it respawns lazily on the next use.
  A recovery lever for a wedged tool-server connection. No-op when nothing is running.
  """
  def restart(server) do
    case Registry.lookup(@registry, server) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@sup, pid)
      [] -> :ok
    end
  end

  defp start(server) do
    with {:ok, spec} <- spec(server),
         {:ok, module} <- Transport.for_spec(spec) do
      spawn_transport(server, spec, module)
    end
  end

  defp spec(server) do
    case Config.mcp_server(server) do
      nil -> {:error, {:unknown_server, server}}
      spec -> {:ok, spec}
    end
  end

  defp spawn_transport(server, spec, module) do
    case DynamicSupervisor.start_child(@sup, %{
           id: {:mcp, server},
           start: {module, :start_link, [spec, [name: via(server, module)]]},
           restart: :temporary
         }) do
      {:ok, pid} ->
        {:ok, pid, module}

      # The server answered "not here" to a Streamable POST. On an explicit
      # `transport: "streamable"` that is the final answer; on the default it means we
      # guessed the newer of two protocols that are told apart only by trying, so try the
      # older one before reporting a failure the operator would read as a broken URL.
      {:error, {:mcp_not_streamable, _}} = error ->
        if module == Client.Http and spec[:transport] in [nil, "auto"] do
          spawn_transport(server, spec, Client.Sse)
        else
          error
        end

      other ->
        other
    end
  end

  defp via(server, module), do: {:via, Registry, {@registry, server, module}}

  @doc "List a server's advertised tools: `{:ok, [%{\"name\", ...}]}` or `{:error, _}`."
  def tools(server) do
    with {:ok, pid, module} <- ensure(server), do: {:ok, module.list_tools(pid)}
  end

  @doc """
  Build OpenAI function specs for the MCP entries in an agent's tool list. Non-MCP
  names are ignored. Servers that fail to start contribute nothing (their tools just
  don't appear), so a missing `npx`/token degrades gracefully.
  """
  def specs_for(names) when is_list(names) do
    names
    |> Enum.filter(&mcp_tool?/1)
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq_by(&get_in(&1, ["function", "name"]))
  end

  def specs_for(_), do: []

  defp expand(name) do
    {server, selector} = parse(name)

    case tools(server) do
      {:ok, tools} ->
        tools
        |> Enum.filter(fn t -> selector == "*" or t["name"] == selector end)
        |> Enum.map(&spec(server, &1))

      _ ->
        []
    end
  end

  @doc "Call an MCP tool by its namespaced name. Returns `{:ok, text} | {:error, reason}`."
  def call(name, args) do
    {server, tool} = parse(name)

    with {:ok, pid, module} <- ensure(server),
         {:ok, out} <- module.call_tool(pid, tool, args) do
      {:ok, out}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # "mcp__<server>__<tool>" -> {server, tool}; "mcp__<server>__*" / "mcp__<server>" -> {server, "*"}
  defp parse("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, "*"] -> {server, "*"}
      [server, tool] -> {server, tool}
      [server] -> {server, "*"}
    end
  end

  defp spec(server, tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => "mcp__" <> server <> "__" <> tool["name"],
        "description" => tool["description"] || "",
        "parameters" => tool["inputSchema"] || %{"type" => "object", "properties" => %{}}
      }
    }
  end
end
