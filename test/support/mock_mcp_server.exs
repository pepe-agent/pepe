# A minimal MCP stdio server used by tests. Speaks JSON-RPC 2.0 over stdin/stdout
# using the OTP-native `:json` module, so it runs under a bare `elixir` process with
# no project deps. It intentionally prints a NON-JSON banner line first, to prove the
# client skips noise without breaking the handshake.

IO.binwrite("mock-mcp server starting (this line is not JSON)\n")

reply = fn map ->
  IO.binwrite(:json.encode(map))
  IO.binwrite("\n")
end

tools = [
  %{
    "name" => "find_organizations",
    "description" => "List organizations (read-only).",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  },
  %{
    "name" => "update_issue",
    "description" => "Change an issue's status (mutating).",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  }
]

loop = fn loop ->
  case IO.read(:stdio, :line) do
    :eof ->
      :ok

    {:error, _} ->
      :ok

    line ->
      case :json.decode(String.trim(line)) do
        %{"method" => "initialize", "id" => id} ->
          reply.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "protocolVersion" => "2025-06-18",
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "mock", "version" => "0.0.1"}
            }
          })

          loop.(loop)

        %{"method" => "tools/list", "id" => id} ->
          reply.(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
          loop.(loop)

        %{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = params} ->
          args = Map.get(params, "arguments", %{})

          reply.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "called #{name} with #{:json.encode(args)}"}
              ]
            }
          })

          loop.(loop)

        _other ->
          # notifications/initialized and anything else: no response.
          loop.(loop)
      end
  end
end

loop.(loop)
