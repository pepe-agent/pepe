defmodule Pepe.MCP.Client.Sse do
  @moduledoc """
  MCP over the **legacy HTTP+SSE pair** (spec revision 2024-11-05), for remote servers that
  have not moved to Streamable HTTP.

  Unlike every other transport here, the two directions travel separately. A GET opens an
  event stream that stays open for the life of the connection and carries **everything the
  server says**; the client's own messages go out as POSTs to a second URL, which the client
  does not know in advance - the server's first event on the stream is
  `event: endpoint`, whose payload is that POST URL (often relative, and usually carrying the
  session id as a query parameter). Nothing can be sent until that arrives.

  That shape is why this is its own module rather than a flag on `Pepe.MCP.Client.Http`: a
  reply is not the answer to the request that provoked it, it is a frame on a long-lived
  stream that has to be matched back to a pending call by JSON-RPC id - the same
  correlation the stdio transport does, and the opposite of Streamable HTTP's one
  request/one response.

  The reader runs in a linked process feeding frames back as messages. Linked on purpose: a
  client whose stream has died has no way to hear anything ever again, so it should die too
  and let `Pepe.MCP` start a fresh one on the next use.
  """

  @behaviour Pepe.MCP.Transport

  use GenServer

  require Logger

  alias Pepe.MCP.OAuth
  alias Pepe.MCP.Protocol
  alias Pepe.MCP.SSE

  @handshake_timeout 30_000
  @call_timeout 60_000

  ###
  ### API
  ###

  @impl Pepe.MCP.Transport
  def start_link(spec, opts \\ []), do: GenServer.start_link(__MODULE__, spec, opts)

  @impl Pepe.MCP.Transport
  def list_tools(pid), do: GenServer.call(pid, :list_tools)

  @impl Pepe.MCP.Transport
  def call_tool(pid, name, args),
    do: GenServer.call(pid, {:call_tool, name, args}, @call_timeout + 5_000)

  ###
  ### server
  ###

  @impl GenServer
  def init(spec) do
    state = %{
      spec: spec,
      url: spec.url,
      endpoint: nil,
      token: nil,
      tools: [],
      next_id: 100,
      pending: %{},
      buffer: "",
      reader: nil
    }

    with {:ok, state} <- authorize(state),
         {:ok, state} <- open_stream(state),
         {:ok, state} <- await_endpoint(state),
         {:ok, state} <- handshake(state) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state), do: {:reply, state.tools, state}

  def handle_call({:call_tool, name, args}, from, state) do
    id = state.next_id
    request = Protocol.request(id, "tools/call", %{"name" => name, "arguments" => args || %{}})

    case send_message(state, request) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | next_id: id + 1}}
    end
  end

  @impl GenServer
  def handle_info({:sse_data, data}, state) do
    {events, buffer} = SSE.consume(data, state.buffer)
    {:noreply, Enum.reduce(events, %{state | buffer: buffer}, &dispatch_event/2)}
  end

  def handle_info({:sse_closed, reason}, state) do
    Logger.warning("[mcp] event stream closed (#{inspect(reason)})")
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :server_down})
    {:stop, :normal, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A reply to something we asked. Progress notifications carry no id and are ignored, as is
  # a reply to an id nobody is waiting for (a call that already timed out).
  defp dispatch_event(%{event: "message", data: data}, state) do
    case Jason.decode(data) do
      {:ok, %{"id" => id} = message} ->
        case Map.pop(state.pending, id) do
          {nil, _} -> state
          {from, pending} -> reply(from, message, pending, state)
        end

      _ ->
        state
    end
  end

  defp dispatch_event(_event, state), do: state

  defp reply(from, message, pending, state) do
    GenServer.reply(from, Protocol.tool_result(message))
    %{state | pending: pending}
  end

  ###
  ### stream
  ###

  defp open_stream(state) do
    parent = self()
    url = state.url
    headers = headers(state)

    reader =
      spawn_link(fn ->
        result =
          Req.get(url,
            headers: Map.put(headers, "accept", "text/event-stream"),
            # The whole point of this connection is to stay open with nothing on it for long
            # stretches; a receive timeout would kill an idle-but-healthy stream.
            receive_timeout: :infinity,
            # A dropped stream is not retried here: Req would silently reopen it and replay
            # the `endpoint` event into a client that has already handshaked. Letting the
            # process die instead is the recovery path that already exists - `Pepe.MCP`
            # starts a fresh client, from scratch, on the next use.
            retry: false,
            into: fn {:data, data}, {req, resp} ->
              send(parent, {:sse_data, data})
              {:cont, {req, resp}}
            end
          )

        send(parent, {:sse_closed, stream_end(result)})
      end)

    {:ok, %{state | reader: reader}}
  end

  # `Req.get` returns one of exactly these two, so there is no third clause to write: a
  # catch-all here would be unreachable, which dialyzer says out loud rather than leaving
  # it to rot as reassuring-looking dead code.
  defp stream_end({:ok, %{status: status}}), do: {:status, status}
  defp stream_end({:error, reason}), do: reason

  # Nothing can be sent until the server has told us where to send it.
  defp await_endpoint(state) do
    case collect(state, fn %{event: event, data: data}, _st -> event == "endpoint" && data end) do
      {:ok, target, state} -> {:ok, %{state | endpoint: resolve(state.url, target)}}
      {:error, :timeout} -> {:error, {:mcp_no_endpoint_event, state.url}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The endpoint event's payload is often a path ("/messages?sessionId=..."), which only
  # means anything against the URL we opened the stream on.
  defp resolve(base, target) do
    base |> URI.merge(target) |> URI.to_string()
  end

  ###
  ### handshake
  ###

  defp handshake(state) do
    with :ok <- send_message(state, Protocol.request(1, "initialize", Protocol.initialize_params())),
         {:ok, _init, state} <- await_id(state, 1),
         :ok <- send_message(state, Protocol.notification("notifications/initialized", %{})),
         :ok <- send_message(state, Protocol.request(2, "tools/list", %{})),
         {:ok, response, state} <- await_id(state, 2) do
      {:ok, %{state | tools: Protocol.tools_from(response)}}
    end
  end

  defp await_id(state, id) do
    collect(state, fn %{event: event, data: data}, _st ->
      with true <- event in ["message", nil],
           {:ok, %{"id" => ^id} = message} <- Jason.decode(data) do
        message
      else
        _ -> false
      end
    end)
  end

  # Block on the stream until `match` returns a truthy value for an event, threading the
  # frame buffer so a message split across chunks is not lost between two waits.
  defp collect(state, match) do
    receive do
      {:sse_data, data} ->
        {events, buffer} = SSE.consume(data, state.buffer)
        state = %{state | buffer: buffer}

        case Enum.find_value(events, &match.(&1, state)) do
          nil -> collect(state, match)
          found -> {:ok, found, state}
        end

      {:sse_closed, reason} ->
        {:error, {:mcp_stream_closed, reason}}
    after
      @handshake_timeout -> {:error, :timeout}
    end
  end

  ###
  ### sending
  ###

  defp send_message(%{endpoint: nil}, _message), do: {:error, :no_endpoint}

  defp send_message(state, message) do
    case Req.post(state.endpoint,
           json: message,
           headers: headers(state),
           receive_timeout: @call_timeout,
           # Never retried: a POST here may be a `tools/call`, and a timeout is not proof
           # the tool did not run. A retry that re-sends one is a second side effect.
           retry: false
         ) do
      # The reply does not come back here - it arrives on the event stream. All this has to
      # confirm is that the server took the message.
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp headers(state) do
    %{"mcp-protocol-version" => Protocol.protocol_version()}
    |> maybe_put("authorization", state.token && "Bearer " <> state.token)
    |> Map.merge(configured_headers(state.spec))
  end

  defp configured_headers(spec) do
    spec
    |> Map.get(:headers, %{})
    |> Enum.into(%{}, fn {k, v} -> {String.downcase(to_string(k)), Protocol.interp(to_string(v))} end)
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.into(%{})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp authorize(state) do
    case OAuth.token(state.spec[:name]) do
      {:ok, token} -> {:ok, %{state | token: token}}
      _ -> {:ok, state}
    end
  end
end
