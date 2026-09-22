# A minimal MCP stdio server whose one tool reports the process it runs in: its working
# directory, its arguments, one environment variable it was given (PEPE_PROBE), whether a
# variable of Pepe's own (PEPE_ACP_SENTINEL) leaked to it, and whether it has a PATH. Used to prove what an editor-supplied
# server was actually started with. Bare `elixir`, no project deps, like mock_mcp_server.exs.

reply = fn map ->
  IO.binwrite(:json.encode(map))
  IO.binwrite("\n")
end

tools = [
  %{
    "name" => "probe",
    "description" => "Report cwd, argv and PEPE_PROBE.",
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
              "serverInfo" => %{"name" => "probe", "version" => "0.0.1"}
            }
          })

          loop.(loop)

        %{"method" => "tools/list", "id" => id} ->
          reply.(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
          loop.(loop)

        %{"method" => "tools/call", "id" => id} ->
          text =
            "cwd=#{File.cwd!()} argv=#{Enum.join(System.argv(), "|")} env=#{System.get_env("PEPE_PROBE") || ""} " <>
              "sentinel=#{System.get_env("PEPE_ACP_SENTINEL") || "none"} path=#{if System.get_env("PATH"), do: "yes", else: "no"}"

          reply.(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "result" => %{"content" => [%{"type" => "text", "text" => text}]}
          })

          loop.(loop)

        _other ->
          loop.(loop)
      end
  end
end

loop.(loop)
