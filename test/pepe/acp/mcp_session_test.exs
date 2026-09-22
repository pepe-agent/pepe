defmodule Pepe.ACP.McpSessionTest do
  @moduledoc """
  Editor-supplied MCP servers through a real ACP connection, over the real JSON: an editor
  lists servers in `session/new`, the model is offered their tools, a call to one leaves
  through `session/request_permission` like any other risky tool, and none of it leaks into
  another session or outlives the connection.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Mcp
  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @probe Path.expand("../../support/mock_mcp_probe_server.exs", __DIR__)

  # Reports the tool names it was offered to the test, then calls the editor's tool when
  # asked to ("CALLTOOL") and answers plainly otherwise. Streams when the request does.
  defmodule McpPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{parent: parent}) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      tool_names = for t <- request["tools"] || [], do: t["function"]["name"]
      send(parent, {:llm_tools, tool_names})

      scoped = Enum.find(tool_names, &String.starts_with?(&1, "mcp__editor_"))
      messages = request["messages"]

      wants? =
        Enum.any?(messages, fn m -> m["role"] == "user" and is_binary(m["content"]) and String.contains?(m["content"], "CALLTOOL") end)

      answering? = List.last(messages)["role"] == "tool" or not (wants? and scoped != nil)
      respond(conn, request["stream"] == true, answering?, scoped)
    end

    defp tool_calls(name),
      do: [%{"id" => "call_1", "type" => "function", "function" => %{"name" => name, "arguments" => "{}"}}]

    defp respond(conn, false, true, _scoped), do: json(conn, %{"role" => "assistant", "content" => "All done."}, "stop")

    defp respond(conn, false, false, scoped),
      do: json(conn, %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls(scoped)}, "tool_calls")

    defp respond(conn, true, answering?, scoped) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      chunks =
        if answering?,
          do: [delta(%{"content" => "All done."}), finish("stop")],
          else: [delta(%{"tool_calls" => tool_calls(scoped)}), finish("tool_calls")]

      Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end

    defp json(conn, message, finish_reason) do
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp delta(d), do: "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => d, "finish_reason" => nil}]})}\n\n"

    defp finish(reason),
      do: "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_mcp_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, llm} = Bandit.start_link(plug: {McpPlug, %{parent: self()}}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "editor", model: "mock", tools: ["read_file"], max_iterations: 5})

    project = Path.join(System.tmp_dir!(), "acp_mcp_e2e_project_#{System.unique_integer([:positive])}")
    File.mkdir_p!(project)

    on_exit(fn ->
      Process.exit(llm, :normal)
      File.rm_rf(project)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    test = self()
    server = start_supervised!({Server, writer: fn json -> send(test, {:acp_out, Jason.decode!(json)}) end, agent: "editor"})

    {:ok, server: server, project: project}
  end

  ###
  ### helpers
  ###

  defp send_msg(server, message), do: Server.handle_line(server, Jason.encode!(message))

  defp request(server, id, method, params),
    do: send_msg(server, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp await(fun, timeout \\ 10_000) do
    receive do
      {:acp_out, message} -> if fun.(message), do: message, else: await(fun, timeout)
    after
      timeout -> flunk("no matching ACP message within #{timeout}ms")
    end
  end

  defp await_response(id), do: await(&(&1["id"] == id and not is_map_key(&1, "method")))

  defp await_update(kind),
    do: await(&(&1["method"] == "session/update" and &1["params"]["update"]["sessionUpdate"] == kind))

  defp await_permission_request, do: await(&(&1["method"] == "session/request_permission"))

  defp initialize(server) do
    request(server, 1, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{}})
    await_response(1)
  end

  defp new_session(server, id, cwd, servers) do
    request(server, id, "session/new", %{"cwd" => cwd, "mcpServers" => servers})
    await_response(id)
  end

  defp prompt(server, id, session_id, text) do
    request(server, id, "session/prompt", %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    })
  end

  defp answer(server, request_id, option_id) do
    send_msg(server, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    })
  end

  defp editor_server(name, extra \\ %{}),
    do: Map.merge(%{"name" => name, "command" => "elixir", "args" => [@probe], "env" => []}, extra)

  defp offered_tools do
    assert_receive {:llm_tools, names}, 10_000
    names
  end

  ###
  ### tests
  ###

  test "the handshake says which remote MCP transports it takes", %{server: server} do
    caps = initialize(server)["result"]["agentCapabilities"]
    assert caps["mcpCapabilities"] == %{"http" => true, "sse" => true}
  end

  test "an editor's server is offered to the model, and calling it asks first, then runs in the project", %{
    server: server,
    project: project
  } do
    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])

    prompt(server, 3, session_id, "CALLTOOL please")
    assert "mcp__editor_probe__probe" in offered_tools()

    call = await_update("tool_call")["params"]["update"]
    assert call["_meta"]["pepe"]["tool"] == "mcp__editor_probe__probe"

    # Not in the always-safe set and not pre-approved: it stops for a human like any other
    # risky tool, through the editor's own permission prompt.
    ask = await_permission_request()
    assert ask["params"]["toolCall"]["toolCallId"] == call["toolCallId"]
    answer(server, ask["id"], "once")

    done = await_update("tool_call_update")["params"]["update"]
    assert done["status"] == "completed"
    assert hd(done["content"])["content"]["text"] =~ Path.basename(project)

    assert await_response(3)["result"]["stopReason"] == "end_turn"
  end

  test "a refusal at the prompt means the server's tool never ran", %{server: server, project: project} do
    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])

    prompt(server, 3, session_id, "CALLTOOL please")
    ask = await_permission_request()
    answer(server, ask["id"], "deny")

    done = await_update("tool_call_update")["params"]["update"]
    assert done["status"] == "failed"
    refute hd(done["content"])["content"]["text"] =~ "cwd="
  end

  test "a grant for a configured server of the same name does not cover the editor's", %{server: server, project: project} do
    Config.put_agent(%Agent{
      name: "editor",
      model: "mock",
      tools: ["read_file"],
      max_iterations: 5,
      auto_approve: ["mcp__probe__*", "mcp__probe__probe"]
    })

    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])

    prompt(server, 3, session_id, "CALLTOOL please")
    assert "mcp__editor_probe__probe" in offered_tools()

    # Had the editor's server inherited the configured `probe` grant, this call would have
    # run without anyone being asked.
    assert %{"method" => "session/request_permission"} = await_permission_request()
  end

  test "a grant naming the editor's own tool does apply: the agent's policy decides, not the editor", %{server: server, project: project} do
    Config.put_agent(%Agent{
      name: "editor",
      model: "mock",
      tools: ["read_file"],
      max_iterations: 5,
      auto_approve: ["mcp__editor_probe__probe"]
    })

    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])

    prompt(server, 3, session_id, "CALLTOOL please")

    done = await_update("tool_call_update")["params"]["update"]
    assert done["status"] == "completed"
    assert hd(done["content"])["content"]["text"] =~ Path.basename(project)
    refute_received {:acp_out, %{"method" => "session/request_permission"}}
  end

  test "what the editor's server returns is outside content: marked untrusted, and it taints the run", %{server: server, project: project} do
    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])
    key = "acp:#{session_id}"
    assert [_] = Mcp.specs(key)

    call = %{"id" => "c1", "function" => %{"name" => "mcp__editor_probe__probe", "arguments" => "{}"}}
    out = Pepe.Tools.execute(call, %{mcp_scope: key})

    assert out =~ "BEGIN UNTRUSTED EXTERNAL CONTENT (source: mcp:mcp__editor_probe__probe"
    assert Pepe.Agent.Runtime.outside_content?("mcp__editor_probe__probe")
  end

  test "another session on the same connection is not offered the first one's tools", %{server: server, project: project} do
    initialize(server)
    %{"result" => %{"sessionId" => with_servers}} = new_session(server, 2, project, [editor_server("probe")])
    %{"result" => %{"sessionId" => without}} = new_session(server, 3, project, [])

    prompt(server, 4, without, "CALLTOOL please")
    refute Enum.any?(offered_tools(), &String.starts_with?(&1, "mcp__editor_"))
    assert await_response(4)["result"]["stopReason"] == "end_turn"

    prompt(server, 5, with_servers, "just answer")
    assert "mcp__editor_probe__probe" in offered_tools()
  end

  test "a server that will not start is reported in the panel and the turn still answers", %{server: server, project: project} do
    initialize(server)

    servers = [editor_server("gone", %{"command" => "definitely-not-a-real-binary-xyz"})]
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, servers)

    prompt(server, 3, session_id, "just answer")

    notice = await_update("agent_message_chunk")["params"]["update"]["content"]["text"]
    assert notice =~ "MCP server `gone`"
    assert notice =~ "not found on PATH"

    refute Enum.any?(offered_tools(), &String.starts_with?(&1, "mcp__editor_"))
    assert await_response(3)["result"]["stopReason"] == "end_turn"
  end

  test "a malformed mcpServers is an invalid request, but a malformed server is not", %{server: server, project: project} do
    initialize(server)

    assert new_session(server, 2, project, "nope")["error"]["code"] == -32_602

    assert %{"result" => %{"sessionId" => _}} = new_session(server, 3, project, [%{"name" => "x", "command" => "./relative"}, 42])
  end

  test "the servers stop when the connection ends", %{server: server, project: project} do
    initialize(server)
    %{"result" => %{"sessionId" => session_id}} = new_session(server, 2, project, [editor_server("probe")])
    key = "acp:#{session_id}"

    assert [_] = Mcp.specs(key)

    ref = Process.monitor(server)
    stop_supervised!(Server)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

    eventually(fn -> Mcp.specs(key) == [] end)
  end

  defp eventually(fun, tries \\ 150) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          20 -> eventually(fun, tries - 1)
        end
    end
  end
end
