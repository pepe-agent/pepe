defmodule Pepe.ACP.Mcp.Manager do
  @moduledoc """
  Which editor-supplied MCP servers belong to which ACP session, and whether they are up.

  One entry per *scope* (the ACP session's key). Each entry owns its servers, the tools they
  advertise, the notices waiting to be shown to the person in the editor, and a monitor on
  the connection that attached them: when that connection goes away, so do the servers.

  ## Why a process, and why startup is asynchronous

  A client's handshake can take thirty seconds against a server that never answers, and
  `session/new` is answered by the connection's single process. So `attach` only validates
  and registers; each server starts in its own task and reports back, and the first turn
  waits for them (bounded, see `Pepe.ACP.Mcp.specs/1`) instead of the connection doing so.
  A server that has not finished by then is left out of that turn and picked up by the next
  one that finds it ready - it is never waited on twice.

  ## Generations

  Attaching to a scope that already has servers replaces them. A start that finishes after
  its scope was replaced or dropped belongs to a generation nobody is waiting for; its
  client is stopped rather than adopted, and it is registered under a key that includes the
  generation so stopping it cannot touch its replacement.
  """

  use GenServer

  require Logger

  alias Pepe.ACP.Mcp.Descriptor
  alias Pepe.ACP.Mcp.Failure
  alias Pepe.ACP.Mcp.Supervisor, as: McpSupervisor

  @max_tools 64
  @tool_name_length 48
  @description_length 1024

  ###
  ### API
  ###

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Register `servers` for `scope`, owned by `owner`, and start them in the background.
  Returns `{:ok, %{accepted: [name], rejected: [{name, reason}]}}` at once.
  """
  def attach(scope, owner, servers, cwd),
    do: GenServer.call(__MODULE__, {:attach, scope, owner, servers, cwd})

  @doc "Stop and forget everything attached to `scope`."
  def detach(scope), do: GenServer.cast(__MODULE__, {:detach, scope})

  @doc "Wait up to `timeout` ms for every server of `scope` still starting. `:ok | :timeout`."
  def await(scope, timeout), do: GenServer.call(__MODULE__, {:await, scope, timeout}, timeout + 5_000)

  @doc "OpenAI tool specs for the servers of `scope` that are up."
  def specs(scope), do: GenServer.call(__MODULE__, {:specs, scope})

  @doc "The notices not yet shown for `scope`, once."
  def notices(scope), do: GenServer.call(__MODULE__, {:notices, scope})

  @doc "Resolve a namespaced tool name against `scope`'s own servers."
  def lookup(scope, name), do: GenServer.call(__MODULE__, {:lookup, scope, name})

  @doc "The supervisor reference a scope's server `ns` starts under."
  def supervisor_for(scope, ns), do: {:via, PartitionSupervisor, {McpSupervisor.dynsup(), {scope, ns}}}

  ###
  ### server
  ###

  @impl true
  def init(:ok) do
    # So terminate/2 runs on shutdown and can stop what is still running.
    Process.flag(:trap_exit, true)
    {:ok, %{scopes: %{}}}
  end

  @impl true
  def handle_call({:attach, scope, owner, servers, cwd}, _from, state) do
    state = drop_scope(state, scope)
    {accepted, rejected} = Descriptor.normalize(servers, cwd: cwd)

    reply = {:ok, %{accepted: Enum.map(accepted, & &1.name), rejected: rejected}}

    if accepted == [] and rejected == [] do
      {:reply, reply, state}
    else
      gen = make_ref()

      entry = %{
        owner: owner,
        ref: Process.monitor(owner),
        gen: gen,
        servers: Map.new(accepted, &{&1.ns, new_server(scope, gen, &1)}),
        order: Enum.map(accepted, & &1.ns),
        notices: Enum.map(rejected, fn {name, reason} -> "MCP server `#{name}` from your editor was not used: #{reason}." end),
        waiters: []
      }

      Enum.each(accepted, &start_async(scope, gen, &1))
      {:reply, reply, put_in(state.scopes[scope], entry)}
    end
  end

  def handle_call({:await, scope, timeout}, from, state) do
    case state.scopes[scope] do
      %{} = entry ->
        if starting?(entry) do
          tref = make_ref()
          timer = Process.send_after(self(), {:await_timeout, scope, tref}, timeout)
          {:noreply, put_in(state.scopes[scope], %{entry | waiters: entry.waiters ++ [{tref, from, timer}]})}
        else
          {:reply, :ok, state}
        end

      nil ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:specs, scope}, _from, state) do
    specs =
      case state.scopes[scope] do
        nil ->
          []

        entry ->
          entry.order
          |> Enum.map(&entry.servers[&1])
          |> Enum.filter(&(&1.status == :ready))
          |> Enum.flat_map(&tool_specs/1)
      end

    {:reply, specs, state}
  end

  def handle_call({:notices, scope}, _from, state) do
    case state.scopes[scope] do
      nil -> {:reply, [], state}
      entry -> {:reply, entry.notices, put_in(state.scopes[scope], %{entry | notices: []})}
    end
  end

  def handle_call({:lookup, scope, name}, _from, state) do
    {:reply, resolve(state.scopes[scope], scope, name), state}
  end

  @impl true
  def handle_cast({:detach, scope}, state), do: {:noreply, drop_scope(state, scope)}

  def handle_cast({:started, scope, gen, ns, result}, state) do
    case state.scopes[scope] do
      %{gen: ^gen, servers: %{^ns => server}} = entry ->
        {server, notes} = settle(server, result)
        entry = %{entry | servers: Map.put(entry.servers, ns, server), notices: entry.notices ++ notes}
        {:noreply, state |> put_in([:scopes, scope], entry) |> settle_waiters(scope)}

      _replaced_or_dropped ->
        if match?({:ok, _}, result), do: stop_async([{key(scope, gen, ns), supervisor_for(scope, ns)}])
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:await_timeout, scope, tref}, state) do
    case state.scopes[scope] do
      %{waiters: waiters} = entry ->
        case List.keytake(waiters, tref, 0) do
          {{^tref, from, _timer}, rest} ->
            GenServer.reply(from, :timeout)
            {:noreply, put_in(state.scopes[scope], %{entry | waiters: rest})}

          nil ->
            {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.scopes, fn {_scope, entry} -> entry.ref == ref end) do
      {scope, _entry} -> {:noreply, drop_scope(state, scope)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.scopes), &drop_scope(state, &1))
    :ok
  end

  ###
  ### state helpers
  ###

  defp new_server(scope, gen, server) do
    %{
      name: server.name,
      ns: server.ns,
      transport: server.transport,
      spec: server.spec,
      key: key(scope, gen, server.ns),
      status: :starting,
      # exposed tool name => the tool as the server advertised it
      exposed: %{}
    }
  end

  # The generation is part of the key so a stale start can be stopped without touching the
  # server of the same name that replaced it.
  defp key(scope, gen, ns), do: {:acp_mcp, scope, gen, ns}

  defp starting?(entry), do: Enum.any?(entry.servers, fn {_ns, server} -> server.status == :starting end)

  defp settle_waiters(state, scope) do
    entry = state.scopes[scope]

    if entry.waiters != [] and not starting?(entry) do
      Enum.each(entry.waiters, fn {_tref, from, timer} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, :ok)
      end)

      put_in(state.scopes[scope], %{entry | waiters: []})
    else
      state
    end
  end

  defp drop_scope(state, scope) do
    case Map.pop(state.scopes, scope) do
      {nil, _scopes} ->
        state

      {entry, scopes} ->
        Process.demonitor(entry.ref, [:flush])

        Enum.each(entry.waiters, fn {_tref, from, timer} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, :timeout)
        end)

        entry.servers
        |> Map.values()
        |> Enum.filter(&(&1.status == :ready))
        |> Enum.map(&{&1.key, supervisor_for(scope, &1.ns)})
        |> stop_async()

        %{state | scopes: scopes}
    end
  end

  # Stopping waits on the supervisor a client started under, which is busy for as long as
  # another client's handshake there takes; never do that inside this process.
  defp stop_async([]), do: :ok

  defp stop_async(keys_and_sups) do
    Task.Supervisor.start_child(Pepe.MCP.TaskSupervisor, fn ->
      Enum.each(keys_and_sups, fn {key, sup} -> Pepe.MCP.stop_spec(key, sup) end)
    end)

    :ok
  end

  ###
  ### starting
  ###

  defp start_async(scope, gen, server) do
    Task.Supervisor.start_child(Pepe.MCP.TaskSupervisor, fn ->
      GenServer.cast(__MODULE__, {:started, scope, gen, server.ns, start_server(scope, gen, server)})
    end)
  end

  defp start_server(scope, gen, server) do
    case Pepe.MCP.start_spec(key(scope, gen, server.ns), server.spec, supervisor_for(scope, server.ns)) do
      {:ok, pid, module} -> {:ok, module.list_tools(pid)}
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, _reason -> {:error, {:exception, Atom.to_string(kind)}}
  end

  defp settle(server, {:ok, tools}) do
    {exposed, notes} = expose(server, tools)
    {%{server | status: :ready, exposed: exposed}, notes}
  end

  defp settle(server, {:error, reason}) do
    Logger.warning("[acp] editor MCP server #{server.ns} failed: #{Failure.describe(reason)}")

    note =
      "MCP server `#{server.name}`#{where(server)} from your editor #{Failure.describe(reason)}. " <>
        "Its tools are not available in this session."

    {%{server | status: :failed}, [note]}
  end

  defp where(%{transport: :stdio}), do: ""
  defp where(%{spec: %{url: url}}), do: " (#{Failure.host_label(url)})"

  # The tools a server advertises, made safe to hand to a model: a name a provider would
  # reject (and fail the whole request over) is rewritten, a duplicate is numbered, and no
  # more than @max_tools are offered.
  defp expose(server, tools) do
    valid = Enum.filter(tools, &(is_map(&1) and is_binary(&1["name"]) and &1["name"] != ""))
    {kept, dropped} = Enum.split(valid, @max_tools)

    {exposed, _used} =
      Enum.reduce(kept, {%{}, MapSet.new()}, fn tool, {acc, used} ->
        name = unique_tool(tool_name(tool["name"]), used)
        {Map.put(acc, name, tool), MapSet.put(used, name)}
      end)

    notes =
      if dropped == [],
        do: [],
        else: ["MCP server `#{server.name}` offers #{length(valid)} tools; only the first #{@max_tools} are available in this session."]

    {exposed, notes}
  end

  defp tool_name(name), do: name |> String.replace(~r/[^A-Za-z0-9_-]/, "_") |> String.slice(0, @tool_name_length)

  defp unique_tool(name, used), do: unique_tool(name, used, name, 2)

  defp unique_tool(base, used, candidate, n) do
    if MapSet.member?(used, candidate), do: unique_tool(base, used, "#{base}_#{n}", n + 1), else: candidate
  end

  defp tool_specs(server) do
    for {exposed, tool} <- Enum.sort(server.exposed) do
      %{
        "type" => "function",
        "function" => %{
          "name" => "mcp__" <> server.ns <> "__" <> exposed,
          "description" => description(server, tool),
          "parameters" => schema(tool["inputSchema"])
        }
      }
    end
  end

  # What the server says about its own tool goes into the model's context, so it is
  # bounded, stripped of control characters, and labelled with where it came from.
  defp description(server, tool) do
    text =
      case tool["description"] do
        text when is_binary(text) -> text |> String.replace(~r/[\x00-\x09\x0B-\x1F\x7F]/, " ") |> String.slice(0, @description_length)
        _ -> ""
      end

    "[tool from the editor's MCP server #{server.ns}] " <> text
  end

  defp schema(%{"type" => "object"} = schema), do: schema
  defp schema(_other), do: %{"type" => "object", "properties" => %{}}

  ###
  ### lookup
  ###

  defp resolve(nil, _scope, _name), do: {:error, "no editor MCP server is attached to this session"}

  defp resolve(entry, scope, name) do
    entry.servers
    |> Map.values()
    |> Enum.find(&String.starts_with?(name, "mcp__" <> &1.ns <> "__"))
    |> case do
      nil ->
        {:error, "no editor MCP server of this session provides `#{name}`"}

      %{status: :ready} = server ->
        exposed = String.replace_prefix(name, "mcp__" <> server.ns <> "__", "")

        case Map.fetch(server.exposed, exposed) do
          {:ok, tool} ->
            {:ok, %{key: server.key, tool: tool["name"], spec: server.spec, sup: supervisor_for(scope, server.ns)}}

          :error ->
            {:error, "the editor's MCP server `#{server.name}` has no tool `#{exposed}`"}
        end

      server ->
        {:error, "the editor's MCP server `#{server.name}` is not running (#{server.status})"}
    end
  end
end
