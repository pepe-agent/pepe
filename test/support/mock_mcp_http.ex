defmodule Pepe.Test.MockMCP do
  @moduledoc """
  A real MCP server over real HTTP, for the remote transports - the same posture as
  `Pepe.Test.MockLLM`: a Bandit server on a loopback port rather than a mocked `Req`, so the
  thing under test is the actual request that would go out.

  Serves all three shapes a remote MCP server can take, chosen per test:

    * `mode: :streamable` - POST `/mcp`, answered as `application/json`.
    * `mode: :streamable_sse` - the same endpoint answering `text/event-stream`, which the
      spec allows for any request and which a client that only parses JSON silently fails on.
    * `mode: :sse` - the legacy pair: GET `/sse` holds the stream open and announces the POST
      URL via an `endpoint` event, POSTs go to `/messages`, replies come back on the stream.

  `tools/call` on `boom` returns `isError: true`, so the "a delivered response can still be a
  failure" path has a server that actually produces one.
  """

  @behaviour Plug

  import Plug.Conn

  @table :mock_mcp_sessions
  @stream_idle_ms 30_000

  @tools [
    %{
      "name" => "recall",
      "description" => "Search memories (read-only).",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "boom",
      "description" => "Always fails, in-band.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @impl true
  def init(opts), do: opts |> Enum.into(%{}) |> Map.put_new(:mode, :streamable)

  @impl true
  def call(conn, opts) do
    case {conn.method, conn.request_path} do
      {"POST", "/mcp"} -> streamable(conn, opts)
      {"GET", "/sse"} -> hold_stream(conn)
      {"POST", "/messages"} -> stream_message(conn)
      _ -> send_resp(conn, 404, "not found")
    end
  end

  ###
  ### streamable HTTP
  ###

  defp streamable(conn, opts) do
    {conn, message} = read_json(conn)

    case respond_to(message) do
      # A notification gets no body, which is what the spec says and what the client has to
      # tolerate rather than trying to parse.
      nil ->
        send_resp(conn, 202, "")

      response ->
        conn
        |> put_session_header(message)
        |> deliver(response, opts.mode)
    end
  end

  defp deliver(conn, response, :streamable_sse) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, "event: message\ndata: #{Jason.encode!(response)}\n\n")
  end

  defp deliver(conn, response, _mode) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  defp put_session_header(conn, %{"method" => "initialize"}),
    do: put_resp_header(conn, "mcp-session-id", "session-abc")

  defp put_session_header(conn, _message), do: conn

  ###
  ### legacy HTTP+SSE
  ###

  defp hold_stream(conn) do
    session = "sse-#{System.unique_integer([:positive])}"
    table()
    :ets.insert(@table, {session, self()})

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    # The bootstrap event: until this lands, the client has nowhere to POST.
    {:ok, conn} = chunk(conn, "event: endpoint\ndata: /messages?sessionId=#{session}\n\n")

    pump(conn)
  end

  defp pump(conn) do
    receive do
      {:push, payload} ->
        case chunk(conn, "event: message\ndata: #{payload}\n\n") do
          {:ok, conn} -> pump(conn)
          _closed -> conn
        end
    after
      @stream_idle_ms -> conn
    end
  end

  defp stream_message(conn) do
    {conn, message} = read_json(conn)
    conn = fetch_query_params(conn)
    session = conn.query_params["sessionId"]

    case respond_to(message) do
      nil -> :ok
      response -> push_to_stream(session, Jason.encode!(response))
    end

    # 202 and nothing else: the answer travels on the held-open stream, not here.
    send_resp(conn, 202, "")
  end

  defp push_to_stream(session, payload) do
    table()

    case :ets.lookup(@table, session) do
      [{^session, pid}] -> send(pid, {:push, payload})
      _ -> :ok
    end
  end

  ###
  ### protocol
  ###

  defp respond_to(%{"method" => "initialize", "id" => id}) do
    result(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "mock-remote", "version" => "0.0.1"}
    })
  end

  defp respond_to(%{"method" => "tools/list", "id" => id}),
    do: result(id, %{"tools" => @tools})

  defp respond_to(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "boom"}}) do
    result(id, %{
      "content" => [%{"type" => "text", "text" => "the upstream said no"}],
      "isError" => true
    })
  end

  defp respond_to(%{"method" => "tools/call", "id" => id, "params" => params}) do
    args = Map.get(params, "arguments", %{})

    result(id, %{
      "content" => [
        %{"type" => "text", "text" => "called #{params["name"]} with #{Jason.encode!(args)}"}
      ]
    })
  end

  # No id means a notification: nothing to answer.
  defp respond_to(_message), do: nil

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  ###
  ### helpers
  ###

  defp read_json(conn) do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body) do
      {:ok, message} -> {conn, message}
      _ -> {conn, %{}}
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> @table
    end
  rescue
    # Two streams racing to create it: whoever lost just uses the winner's.
    ArgumentError -> @table
  end
end
