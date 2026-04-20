defmodule Pepe.MCP.Client do
  @moduledoc """
  A minimal **MCP (Model Context Protocol)** client over stdio.

  Launches an MCP server as a child process (e.g. `npx -y @sentry/mcp-server`),
  speaks JSON-RPC 2.0 line-by-line over its stdin/stdout, performs the
  `initialize` handshake, lists the server's tools, and can call them - so an agent
  can use external tools (Sentry, GitHub, ...) as if they were built in.

  One GenServer per configured server. Robust to noise: any stdout line that isn't
  valid JSON (some packages print a startup banner) is skipped, so it can't break
  the handshake.

  State: `%{port, tools: [%{"name","description","inputSchema"}], next_id, pending}`.
  """

  use GenServer
  require Logger

  @handshake_timeout 30_000
  @call_timeout 60_000

  @client_info %{"name" => "pepe", "version" => "0.1.0"}
  @protocol "2025-06-18"

  ###
  ### API
  ###

  @doc """
  Start a client for a server spec: `%{command: "npx", args: [...], env: %{...}}`.
  `${ENV_VAR}` references in args/env are interpolated at spawn time.
  """
  def start_link(spec, opts \\ []) do
    GenServer.start_link(__MODULE__, spec, opts)
  end

  @doc "The tools the server advertises (`[%{\"name\", \"description\", \"inputSchema\"}]`)."
  def list_tools(pid), do: GenServer.call(pid, :list_tools)

  @doc "Call a tool by name with a map of arguments. Returns `{:ok, text} | {:error, reason}`."
  def call_tool(pid, name, args),
    do: GenServer.call(pid, {:call_tool, name, args}, @call_timeout + 5_000)

  ###
  ### server
  ###

  @impl true
  def init(spec) do
    with {:ok, exe} <- executable(spec),
         {:ok, port} <- open_port(exe, spec) do
      case handshake(port) do
        {:ok, tools} ->
          {:ok, %{port: port, tools: tools, next_id: 100, pending: %{}, buffer: ""}}

        {:error, reason} ->
          safe_close(port)
          {:stop, {:mcp_handshake_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:mcp_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:list_tools, _from, state), do: {:reply, state.tools, state}

  def handle_call({:call_tool, name, args}, from, state) do
    id = state.next_id
    send_rpc(state.port, id, "tools/call", %{"name" => name, "arguments" => args || %{}})
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {messages, rest} = split_json(state.buffer <> data)
    state = Enum.reduce(messages, %{state | buffer: rest}, &dispatch_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[mcp] server exited (status #{status})")
    # Fail any in-flight calls so callers don't hang.
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :server_down})
    {:stop, :normal, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A response to a pending `tools/call`.
  defp dispatch_message(%{"id" => id} = msg, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        GenServer.reply(from, tool_result(msg))
        %{state | pending: pending}
    end
  end

  defp dispatch_message(_notification, state), do: state

  ###
  ### handshake (synchronous, during init)
  ###

  defp handshake(port) do
    send_rpc(port, 1, "initialize", %{
      "protocolVersion" => @protocol,
      "capabilities" => %{},
      "clientInfo" => @client_info
    })

    with {:ok, _init, buf} <- await(port, 1, ""),
         :ok <- send_notification(port, "notifications/initialized", %{}),
         :ok <- send_rpc(port, 2, "tools/list", %{}),
         {:ok, resp, _buf} <- await(port, 2, buf) do
      {:ok, get_in(resp, ["result", "tools"]) || []}
    end
  end

  # Block until a JSON-RPC response with `id` arrives (skipping notifications and
  # non-JSON banner lines), or time out.
  defp await(port, id, buffer) do
    receive do
      {^port, {:data, data}} ->
        {messages, rest} = split_json(buffer <> data)

        case Enum.find(messages, &(&1["id"] == id)) do
          nil -> await(port, id, rest)
          %{"error" => err} -> {:error, err}
          resp -> {:ok, resp, rest}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      @handshake_timeout -> {:error, :timeout}
    end
  end

  ###
  ### port + framing
  ###

  defp executable(%{command: command}) when is_binary(command) do
    case System.find_executable(command) do
      nil -> {:error, {:not_found, command}}
      exe -> {:ok, exe}
    end
  end

  defp executable(_), do: {:error, :no_command}

  defp open_port(exe, spec) do
    args = spec |> Map.get(:args, []) |> Enum.map(&interp/1)
    env = spec |> Map.get(:env, %{}) |> env_list()

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        {:args, args},
        {:env, env}
      ])

    {:ok, port}
  rescue
    e -> {:error, e}
  end

  defp env_list(env) when is_map(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(interp(to_string(v)))}
    end)
  end

  defp env_list(_), do: []

  # Interpolate ${ENV_VAR} references (keeps secrets out of the config file).
  defp interp(value) when is_binary(value), do: Pepe.Config.interpolate(value) || ""
  defp interp(value), do: value

  defp send_rpc(port, id, method, params) do
    line =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    Port.command(port, line <> "\n")
    :ok
  end

  defp send_notification(port, method, params) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
    Port.command(port, line <> "\n")
    :ok
  end

  # Split a buffer into complete JSON messages (one per line) + the trailing partial
  # line. Lines that aren't valid JSON (startup banners, warnings) are skipped.
  defp split_json(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)

    messages =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, msg} when is_map(msg) -> [msg]
          _ -> []
        end
      end)

    {messages, rest}
  end

  # Flatten an MCP tool result's content blocks into text.
  defp tool_result(%{"result" => %{"content" => content}}) when is_list(content) do
    text =
      Enum.map_join(content, "\n", fn
        %{"type" => "text", "text" => t} -> t
        other -> Jason.encode!(other)
      end)

    {:ok, text}
  end

  defp tool_result(%{"result" => result}), do: {:ok, Jason.encode!(result)}
  defp tool_result(%{"error" => error}), do: {:error, error}
  defp tool_result(_), do: {:error, :bad_response}

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _ -> :ok
  end
end
