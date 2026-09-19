defmodule Pepe.ACPTest do
  @moduledoc """
  The Agent Client Protocol surface, driven over real JSON-RPC messages.

  `Pepe.ACP.Server` never touches a pipe - it reads through `handle_line/2` and writes
  through a `:writer` function - so an editor can be simulated here exactly, with the
  test process standing in for the one at the other end of stdout. Everything below is
  the bytes a real client would send.

  Three things are worth proving and are proved here: that the handshake reports only
  what this agent can actually do, that a prompt turn streams back and terminates with
  a stop reason, and that a risky tool call leaves through `Pepe.Permissions.gate/3`
  and comes back as a `session/request_permission` a human answers - allowed and
  refused, since "silently allowed" and "silently denied" are the two failure modes
  that would make the whole surface a lie.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Asks to run `bash` on the first turn, then answers once the tool result comes
  # back. The command trips `Pepe.Permissions.Risk`'s `:network` hint (so the gate
  # actually stops to ask) while being completely inert if it does run: `echo curl`
  # prints the word "curl".
  defmodule BashPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      messages = request["messages"]
      last = List.last(messages)

      answering? = last["role"] == "tool" or not wants_tool?(messages)
      respond(conn, request["stream"] == true, answering?)
    end

    defp wants_tool?(messages) do
      Enum.any?(messages, fn m -> m["role"] == "user" and String.contains?(m["content"] || "", "RUNTOOL") end)
    end

    defp tool_calls do
      [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "bash", "arguments" => ~s({"command":"echo curl"})}
        }
      ]
    end

    defp respond(conn, false, true) do
      json(conn, %{"role" => "assistant", "content" => "All done."}, "stop")
    end

    defp respond(conn, false, false) do
      json(conn, %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls()}, "tool_calls")
    end

    defp respond(conn, true, answering?) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      chunks =
        if answering? do
          [delta(%{"content" => "All done."}), finish("stop")]
        else
          [delta(%{"tool_calls" => tool_calls()}), finish("tool_calls")]
        end

      Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end

    defp json(conn, message, finish_reason) do
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp delta(d) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => d, "finish_reason" => nil}]})}\n\n"
    end

    defp finish(reason) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, llm} = Bandit.start_link(plug: BashPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Config.put_agent(%Agent{name: "editor", model: "mock", tools: ["bash"], max_iterations: 5})

    on_exit(fn ->
      Process.exit(llm, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs first: a turn still in flight must be killed while the
    # config it is running against still exists. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    test = self()
    writer = fn json -> send(test, {:acp_out, Jason.decode!(json)}) end
    server = start_supervised!({Server, writer: writer, agent: "editor"})

    {:ok, server: server, home: home}
  end

  ###
  ### helpers
  ###

  defp send_msg(server, message), do: Server.handle_line(server, Jason.encode!(message))

  defp request(server, id, method, params) do
    send_msg(server, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  # The next outbound message matching `fun`, skipping anything else on the way -
  # a turn interleaves notifications with the response being waited for.
  defp await(fun, timeout \\ 5_000) do
    receive do
      {:acp_out, message} -> if fun.(message), do: message, else: await(fun, timeout)
    after
      timeout -> flunk("no matching ACP message within #{timeout}ms")
    end
  end

  defp await_response(id), do: await(&(&1["id"] == id and not is_map_key(&1, "method")))

  defp await_update(kind),
    do: await(&(&1["method"] == "session/update" and &1["params"]["update"]["sessionUpdate"] == kind))

  defp await_permission_request,
    do: await(&(&1["method"] == "session/request_permission"))

  defp initialize(server) do
    request(server, 1, "initialize", %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}
    })

    await_response(1)
  end

  defp open_session(server) do
    initialize(server)
    request(server, 2, "session/new", %{"cwd" => System.tmp_dir!(), "mcpServers" => []})
    await_response(2)["result"]["sessionId"]
  end

  defp prompt(server, id, session_id, text) do
    request(server, id, "session/prompt", %{
      "sessionId" => session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    })
  end

  defp answer_permission(server, request_id, option_id) do
    send_msg(server, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    })
  end

  ###
  ### handshake
  ###

  describe "initialization" do
    test "reports the protocol version and only the capabilities it actually has", %{server: server} do
      result = initialize(server)["result"]

      assert result["protocolVersion"] == 1
      assert result["agentInfo"]["name"] == "pepe"

      # Absent capabilities are the point: a client that reads these never sends
      # an image block, so there is no half-working path.
      assert result["agentCapabilities"]["loadSession"] == true

      assert result["agentCapabilities"]["sessionCapabilities"] == %{
               "list" => %{},
               "resume" => %{},
               "fork" => %{}
             }

      # This agent's mock model has no vision and no transcription route is configured, so
      # image and audio are not promised; embedded context is text and always works. See
      # test/pepe/acp/prompt_blocks_test.exs for the vision and audio cases.
      assert result["agentCapabilities"]["promptCapabilities"]["image"] == false
      assert result["agentCapabilities"]["promptCapabilities"]["audio"] == false
      assert result["agentCapabilities"]["promptCapabilities"]["embeddedContext"] == true
      assert result["authMethods"] == []
    end

    test "refuses any other request before the handshake", %{server: server} do
      request(server, 7, "session/new", %{"cwd" => "/tmp"})
      assert await_response(7)["error"]["code"] == -32_600
    end

    test "an unimplemented method is reported as such, not silently ignored", %{server: server} do
      initialize(server)
      request(server, 8, "fs/read_text_file", %{"sessionId" => "nope", "path" => "/tmp/x"})

      error = await_response(8)["error"]
      assert error["code"] == -32_601
      assert error["message"] =~ "fs/read_text_file"
    end

    test "a line that is not JSON gets a parse error, and the connection survives", %{server: server} do
      Server.handle_line(server, "{not json\n")
      assert await(&(&1["error"]["code"] == -32_700))

      assert initialize(server)["result"]["protocolVersion"] == 1
    end
  end

  ###
  ### session/new
  ###

  describe "session/new" do
    test "requires an absolute cwd", %{server: server} do
      initialize(server)
      request(server, 3, "session/new", %{"cwd" => "relative/path", "mcpServers" => []})

      assert await_response(3)["error"]["code"] == -32_602
    end

    # Client-supplied MCP servers are accepted now (they used to be refused here); that
    # behavior is pinned in test/pepe/acp/mcp_session_test.exs.

    test "hands back a session id", %{server: server} do
      assert "sess_" <> _ = open_session(server)
    end
  end

  ###
  ### session/prompt
  ###

  describe "a prompt turn" do
    test "streams the answer back and ends with a stop reason", %{server: server} do
      session_id = open_session(server)
      prompt(server, 4, session_id, "just answer")

      chunk = await_update("agent_message_chunk")
      assert chunk["params"]["sessionId"] == session_id
      assert chunk["params"]["update"]["content"]["text"] =~ "All done"

      assert await_response(4)["result"]["stopReason"] == "end_turn"
    end

    test "refuses a content block type it never claimed to accept", %{server: server} do
      session_id = open_session(server)

      request(server, 5, "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "video", "mimeType" => "video/mp4", "data" => "aaaa"}]
      })

      error = await_response(5)["error"]
      assert error["code"] == -32_602
      assert error["message"] =~ "video"
    end

    test "an unknown session id is an error, not a new session", %{server: server} do
      initialize(server)
      prompt(server, 6, "sess_nope", "hi")

      assert await_response(6)["error"]["message"] =~ "session/new"
    end
  end

  ###
  ### permissions
  ###

  describe "a tool call that needs a human" do
    test "becomes a permission request, and the answer lets it run", %{server: server} do
      session_id = open_session(server)
      prompt(server, 9, session_id, "RUNTOOL please")

      # Announced before the gate runs, so the editor can render the call it is about
      # to be asked about.
      call = await_update("tool_call")["params"]["update"]
      assert call["name"] == "bash"
      assert call["kind"] == "execute"
      assert call["status"] == "pending"
      assert call["rawInput"]["command"] == "echo curl"

      ask = await_permission_request()
      assert ask["params"]["sessionId"] == session_id
      assert ask["params"]["toolCall"]["toolCallId"] == call["toolCallId"]
      assert ask["params"]["toolCall"]["rawInput"]["command"] == "echo curl"

      # The options are Pepe's own decisions, carried by their stable tokens, with
      # ACP's four display kinds layered on top.
      options = ask["params"]["options"]
      ids = Enum.map(options, & &1["optionId"])
      assert "once" in ids
      assert "always" in ids
      assert "deny" in ids
      assert Enum.find(options, &(&1["optionId"] == "once"))["kind"] == "allow_once"
      assert Enum.find(options, &(&1["optionId"] == "deny"))["kind"] == "reject_once"

      answer_permission(server, ask["id"], "once")

      done = await_update("tool_call_update")["params"]["update"]
      assert done["toolCallId"] == call["toolCallId"]
      assert done["status"] == "completed"
      assert hd(done["content"])["content"]["text"] =~ "curl"

      assert await_response(9)["result"]["stopReason"] == "end_turn"
    end

    test "a refusal stops the tool and comes back as a failed call", %{server: server} do
      session_id = open_session(server)
      prompt(server, 10, session_id, "RUNTOOL please")

      call = await_update("tool_call")["params"]["update"]
      ask = await_permission_request()
      answer_permission(server, ask["id"], "deny")

      done = await_update("tool_call_update")["params"]["update"]
      assert done["toolCallId"] == call["toolCallId"]
      assert done["status"] == "failed"
      # What the model is told, verbatim from Pepe.Permissions - no second vocabulary.
      assert hd(done["content"])["content"]["text"] =~ "did not authorize"

      assert await_response(10)["result"]["stopReason"] == "end_turn"
    end

    test "a cancelled outcome is not read as a refusal", %{server: server} do
      session_id = open_session(server)
      prompt(server, 11, session_id, "RUNTOOL please")

      await_update("tool_call")
      ask = await_permission_request()

      send_msg(server, %{
        "jsonrpc" => "2.0",
        "id" => ask["id"],
        "result" => %{"outcome" => %{"outcome" => "cancelled"}}
      })

      done = await_update("tool_call_update")["params"]["update"]
      assert done["status"] == "failed"

      # "nobody answered" and "the user said no" are different facts with different
      # next moves, and the model has to be told the right one.
      text = hd(done["content"])["content"]["text"]
      assert text =~ "Silence is not consent"
      refute text =~ "did not authorize"
    end
  end

  ###
  ### cancellation
  ###

  describe "session/cancel" do
    test "ends the turn with the stop reason ACP requires", %{server: server} do
      session_id = open_session(server)
      prompt(server, 12, session_id, "RUNTOOL please")

      # Cancel while the turn is parked on a permission request nobody answered.
      await_permission_request()
      send_msg(server, %{"jsonrpc" => "2.0", "method" => "session/cancel", "params" => %{"sessionId" => session_id}})

      assert await_response(12)["result"]["stopReason"] == "cancelled"
    end
  end

  ###
  ### cwd_override - a tool call must resolve inside the project the editor has open,
  ### never the agent's own persistent workspace (see Pepe.Agent.Workspace's own doc)
  ###

  # Always asks to read "marker.txt" (a relative path), then answers once the tool
  # result comes back - unlike BashPlug, there is no risk hint on a plain in-workspace
  # read_file, so no permission round trip is expected. Mirrors BashPlug's own
  # stream-vs-not branching: the ACP editor agent is streaming, and a JSON body
  # answering a streamed request parses as an empty stream, silently losing the tool
  # call - the failure mode this test itself hit once while it was being written.
  defmodule ReadFilePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      last = List.last(request["messages"])
      answering? = last["role"] == "tool"
      respond(conn, request["stream"] == true, answering?)
    end

    defp tool_calls do
      [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "read_file", "arguments" => ~s({"path":"marker.txt"})}
        }
      ]
    end

    defp respond(conn, false, true) do
      json(conn, %{"role" => "assistant", "content" => "Read it."}, "stop")
    end

    defp respond(conn, false, false) do
      json(conn, %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls()}, "tool_calls")
    end

    defp respond(conn, true, answering?) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      chunks =
        if answering? do
          [delta(%{"content" => "Read it."}), finish("stop")]
        else
          [delta(%{"tool_calls" => tool_calls()}), finish("tool_calls")]
        end

      Enum.each(chunks ++ ["data: [DONE]\n\n"], fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end

    defp json(conn, message, finish_reason) do
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp delta(d) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => d, "finish_reason" => nil}]})}\n\n"
    end

    defp finish(reason) do
      "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]})}\n\n"
    end
  end

  describe "cwd_override" do
    test "a read_file call resolves against the editor's cwd, not the agent's own workspace", %{server: server} do
      project = Path.join(System.tmp_dir!(), "acp_project_#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      File.write!(Path.join(project, "marker.txt"), "from the editor's project")

      {:ok, llm} = Bandit.start_link(plug: ReadFilePlug, port: 0, scheme: :http)
      {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

      on_exit(fn ->
        Process.exit(llm, :normal)
        File.rm_rf(project)
      end)

      Config.put_model(%Model{name: "mock_rf", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
      Config.put_agent(%Agent{name: "editor", model: "mock_rf", tools: ["read_file"], max_iterations: 5})

      initialize(server)
      request(server, 20, "session/new", %{"cwd" => project, "mcpServers" => []})
      session_id = await_response(20)["result"]["sessionId"]

      prompt(server, 21, session_id, "read the marker")

      done = await_update("tool_call_update")["params"]["update"]
      assert hd(done["content"])["content"]["text"] =~ "from the editor's project"
      assert await_response(21)["result"]["stopReason"] == "end_turn"

      refute File.exists?(Path.join(Pepe.Agent.Workspace.dir("editor"), "marker.txt"))
    end
  end
end
