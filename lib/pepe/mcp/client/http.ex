defmodule Pepe.MCP.Client.Http do
  @moduledoc """
  MCP over **Streamable HTTP** (spec revision 2025-03-26): one endpoint, one POST per
  JSON-RPC message, and the answer either as `application/json` or as a short
  `text/event-stream` the server closes once it has replied. This is what a remote MCP
  server published today speaks, and the reason a hosted server no longer needs a local
  `npx` bridge process to be usable from Pepe.

  Two details of the transport that are easy to miss and expensive to get wrong:

    * **The session id.** A server may answer `initialize` with an `Mcp-Session-Id` header,
      and every later message has to carry it back. Drop it and the server treats each call
      as a new unauthenticated conversation - which usually surfaces as tools that list fine
      and then fail one call later, not as an obvious connection error.
    * **Two content types for one request.** The same POST can come back as a single JSON
      object or as an event stream carrying that same object, at the server's discretion and
      with no way to ask for one. Both are handled here; a client that reads only the first
      works against some servers and mysteriously hangs against others.

  Calls run in a task rather than in the GenServer, so one slow tool does not block another
  agent's call to the same server - matching what the stdio transport gets for free from its
  port being asynchronous.
  """

  @behaviour Pepe.MCP.Transport

  use GenServer

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
      session: nil,
      token: nil,
      tools: [],
      next_id: 100
    }

    with {:ok, state} <- authorize(state),
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
    snapshot = state

    # Off the GenServer so concurrent calls to one server overlap instead of queueing.
    Task.Supervisor.start_child(Pepe.MCP.TaskSupervisor, fn ->
      GenServer.reply(from, exchange(snapshot, request, id))
    end)

    {:noreply, %{state | next_id: id + 1}}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  ###
  ### handshake
  ###

  defp handshake(state) do
    request = Protocol.request(1, "initialize", Protocol.initialize_params())

    case post(state, request, @handshake_timeout) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        state = %{state | session: session_id(resp) || state.session}

        with :ok <- notify_initialized(state),
             {:ok, tools} <- list_tools_now(state) do
          {:ok, %{state | tools: tools}}
        end

      # The two ways a server says "this is not the Streamable endpoint". 405 is the spec's
      # own answer for a method it does not take here; 404 is what a server exposing only the
      # legacy pair returns for a POST to its SSE path. Both are reported distinctly so
      # `Pepe.MCP` can retry over the legacy transport instead of surfacing a dead end.
      {:ok, %{status: status}} when status in [404, 405] ->
        {:error, {:mcp_not_streamable, status}}

      {:ok, %{status: 401} = resp} ->
        {:error, {:mcp_unauthorized, OAuth.challenge(resp)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:mcp_http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, {:mcp_unreachable, reason}}
    end
  end

  defp notify_initialized(state) do
    case post(state, Protocol.notification("notifications/initialized", %{}), @handshake_timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:mcp_http_error, status, "notifications/initialized"}}
      {:error, reason} -> {:error, {:mcp_unreachable, reason}}
    end
  end

  defp list_tools_now(state) do
    case exchange(state, Protocol.request(2, "tools/list", %{}), 2, :raw) do
      {:ok, response} -> {:ok, Protocol.tools_from(response)}
      {:error, reason} -> {:error, {:mcp_tools_failed, reason}}
    end
  end

  ###
  ### request/response
  ###

  # One JSON-RPC round trip. `:raw` returns the decoded envelope (what the handshake needs);
  # the default turns it into the tool text an agent sees.
  defp exchange(state, request, id, mode \\ :tool) do
    case post(state, request, @call_timeout, retry_for(mode)) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        case extract(resp, id) do
          {:ok, response} -> if mode == :raw, do: {:ok, response}, else: Protocol.tool_result(response)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `retry:` is per-message on purpose. The handshake is safe to retry - `initialize` and
  # `tools/list` read and change nothing - but a `tools/call` is whatever the tool does, and
  # a timeout is not proof it did not run. Retrying one that already created an issue creates
  # a second one. The stdio transport has never retried anything; this keeps that promise.
  defp post(state, message, timeout, retry \\ :transient) do
    Req.post(state.url,
      json: message,
      headers: headers(state),
      receive_timeout: timeout,
      retry: retry
    )
  end

  # A handshake read (`:raw`) may be retried; a tool call may not.
  defp retry_for(:raw), do: :transient
  defp retry_for(_mode), do: false

  defp headers(state) do
    base = %{
      # Both, because the server picks which one it answers with.
      "accept" => "application/json, text/event-stream",
      "mcp-protocol-version" => Protocol.protocol_version()
    }

    base
    |> maybe_put("mcp-session-id", state.session)
    |> maybe_put("authorization", state.token && "Bearer " <> state.token)
    |> Map.merge(configured_headers(state.spec))
  end

  # Operator-configured headers win: an explicit `Authorization` in the config is a
  # deliberate choice (a static API key) and must not be silently replaced by a stored
  # OAuth token that happens to also exist.
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

  defp session_id(resp) do
    case Req.Response.get_header(resp, "mcp-session-id") do
      [id | _] -> id
      _ -> nil
    end
  end

  # The response body is either the JSON-RPC object itself, or an event stream carrying it.
  defp extract(resp, id) do
    if event_stream?(resp) do
      from_stream(resp.body, id)
    else
      from_json(resp.body)
    end
  end

  defp event_stream?(resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp from_json(body) when is_map(body), do: {:ok, body}

  defp from_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, {:bad_response, truncate(body)}}
    end
  end

  defp from_json(body), do: {:error, {:bad_response, truncate(body)}}

  # Find our own answer in the stream: a server is free to also send progress notifications
  # (no id) and, on a resumed session, replies to other requests.
  defp from_stream(body, id) when is_binary(body) do
    {events, rest} = SSE.consume(body, "")

    (events ++ SSE.flush(rest))
    |> Enum.flat_map(fn %{data: data} ->
      case Jason.decode(data) do
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end
    end)
    |> Enum.find(&(&1["id"] == id))
    |> case do
      nil -> {:error, {:no_response_for, id}}
      response -> {:ok, response}
    end
  end

  defp from_stream(body, _id), do: {:error, {:bad_response, truncate(body)}}

  ###
  ### auth
  ###

  # A stored OAuth token, refreshed if it is past due. No token is not an error here: a
  # server behind a static API key header needs none, and one that does need OAuth answers
  # 401, which says so far more precisely than a guess made before the first request.
  defp authorize(state) do
    case OAuth.token(state.spec[:name]) do
      {:ok, token} -> {:ok, %{state | token: token}}
      _ -> {:ok, state}
    end
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp truncate(body), do: body |> inspect() |> String.slice(0, 500)
end
