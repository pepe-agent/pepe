defmodule Pepe.ACP.PromptBlocksTest do
  @moduledoc """
  The prompt content blocks end to end: a real `Pepe.ACP.Server`, real JSON-RPC, and a real
  model endpoint (a local plug) that records exactly what it was sent. `Pepe.ACP.ContentTest`
  covers the decisions; this proves they reach the model, and reach the person.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>

  # Records every request body it is sent, then answers "ok" (streamed, because the ACP
  # surface streams whenever the agent's hooks allow it).
  defmodule CapturePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(opts[:test], {:llm_request, body})

      if Jason.decode!(body)["stream"] == true do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        chunk1 = "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => nil}]})}\n\n"
        chunk2 = "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n"
        Enum.each([chunk1, chunk2, "data: [DONE]\n\n"], fn c -> {:ok, _} = chunk(conn, c) end)
        conn
      else
        payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]}
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end
  end

  setup context do
    home = Path.join(System.tmp_dir!(), "pepe_acp_blocks_#{System.unique_integer([:positive])}")
    project = Path.join(home, "project")
    File.mkdir_p!(project)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, llm} = Bandit.start_link(plug: {CapturePlug, test: self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model",
      vision: Map.get(context, :vision, true)
    })

    Config.put_agent(%Agent{name: "editor", model: "mock", tools: [], max_iterations: 3})
    if context[:transcriber], do: Config.put_media("audio", %{"command" => "basename {file}"})

    on_exit(fn ->
      Process.exit(llm, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs first: see Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    test = self()
    writer = fn json -> send(test, {:acp_out, Jason.decode!(json)}) end
    server = start_supervised!({Server, writer: writer, agent: "editor"})

    {:ok, server: server, project: project}
  end

  ###
  ### helpers (small copies of the ones in acp_test.exs, so this file stands alone)
  ###

  defp request(server, id, method, params),
    do: Server.handle_line(server, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}))

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

  defp initialize(server) do
    request(server, 1, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{}})
    await_response(1)
  end

  defp open_session(server, project) do
    initialize(server)
    request(server, 2, "session/new", %{"cwd" => project, "mcpServers" => []})
    await_response(2)["result"]["sessionId"]
  end

  defp prompt(server, id, session_id, blocks),
    do: request(server, id, "session/prompt", %{"sessionId" => session_id, "prompt" => blocks})

  defp text(t), do: %{"type" => "text", "text" => t}

  # What the model was actually sent for the one turn this test ran.
  defp llm_request do
    assert_receive {:llm_request, body}, 5_000
    body
  end

  ###
  ### capabilities
  ###

  describe "initialize" do
    test "promises images for a vision model, no audio without a transcription route", %{server: server} do
      caps = initialize(server)["result"]["agentCapabilities"]["promptCapabilities"]
      assert caps == %{"image" => true, "audio" => false, "embeddedContext" => true}
    end

    @tag vision: false
    test "does not promise images to a model that cannot see them", %{server: server} do
      assert initialize(server)["result"]["agentCapabilities"]["promptCapabilities"]["image"] == false
    end

    @tag transcriber: true
    test "promises audio once a transcription route exists", %{server: server} do
      assert initialize(server)["result"]["agentCapabilities"]["promptCapabilities"]["audio"] == true
    end
  end

  ###
  ### what reaches the model
  ###

  describe "images" do
    test "reach a vision model as an actual image", %{server: server, project: project} do
      session_id = open_session(server, project)
      prompt(server, 3, session_id, [text("what is this?"), %{"type" => "image", "mimeType" => "image/png", "data" => Base.encode64(@png)}])

      assert await_response(3)["result"]["stopReason"] == "end_turn"

      body = llm_request()
      assert body =~ "what is this?"
      assert body =~ "image_url"
      assert body =~ "data:image/png;base64,"
    end

    @tag vision: false
    test "are never silently dropped by a model without eyes", %{server: server, project: project} do
      session_id = open_session(server, project)
      prompt(server, 3, session_id, [text("what is this?"), %{"type" => "image", "data" => Base.encode64(@png)}])

      # The person hears why, in the stream, before the answer.
      note = await_update("agent_message_chunk")["params"]["update"]["content"]["text"]
      assert note =~ "Note: The attached image was not included"
      assert note =~ "can't see images"

      assert await_response(3)["result"]["stopReason"] == "end_turn"

      # ...and so does the model, or it would answer as though it had looked.
      body = llm_request()
      refute body =~ "image_url"
      assert body =~ "The attached image was not included"
    end
  end

  describe "context the editor attaches" do
    test "a file mentioned by link is read and handed over with the prompt", %{server: server, project: project} do
      File.write!(Path.join(project, "notes.md"), "the launch is on Thursday")
      session_id = open_session(server, project)

      prompt(server, 3, session_id, [
        text("when is the launch?"),
        %{"type" => "resource_link", "uri" => "file://" <> Path.join(project, "notes.md"), "name" => "notes.md"}
      ])

      assert await_response(3)["result"]["stopReason"] == "end_turn"
      body = llm_request()
      assert body =~ "when is the launch?"
      assert body =~ "the launch is on Thursday"
    end

    test "a link outside the project is only a pointer, never read", %{server: server, project: project} do
      outside = Path.join(Path.dirname(project), "outside.txt")
      File.write!(outside, "not for the model")
      session_id = open_session(server, project)

      prompt(server, 3, session_id, [%{"type" => "resource_link", "uri" => "file://" <> outside, "name" => "outside.txt"}])

      assert await_response(3)["result"]["stopReason"] == "end_turn"
      body = llm_request()
      refute body =~ "not for the model"
      assert body =~ "outside.txt"
    end

    test "an embedded text resource arrives framed with its URI", %{server: server, project: project} do
      session_id = open_session(server, project)

      prompt(server, 3, session_id, [
        text("explain"),
        %{
          "type" => "resource",
          "resource" => %{"uri" => "file:///proj/a.ex", "mimeType" => "text/x-elixir", "text" => "defmodule Selected do\nend"}
        }
      ])

      assert await_response(3)["result"]["stopReason"] == "end_turn"
      body = llm_request()
      assert body =~ "defmodule Selected do"
      assert body =~ "file:///proj/a.ex"
    end
  end

  describe "audio" do
    @tag transcriber: true
    test "is transcribed and answered as the message it is", %{server: server, project: project} do
      session_id = open_session(server, project)
      # Long enough to clear the transcriber's "empty or truncated" floor; the test command
      # answers with the scratch file's own name, which proves the format was read off the bytes.
      audio = "OggS" <> :binary.copy(<<0>>, 2_000)

      prompt(server, 3, session_id, [%{"type" => "audio", "mimeType" => "audio/ogg", "data" => Base.encode64(audio)}])

      assert await_response(3)["result"]["stopReason"] == "end_turn"
      body = llm_request()
      assert body =~ "pepe_acp_audio_"
      assert body =~ ".ogg"
    end

    test "without a route it is refused out loud, not silently lost", %{server: server, project: project} do
      session_id = open_session(server, project)
      prompt(server, 3, session_id, [text("hello"), %{"type" => "audio", "data" => Base.encode64("OggS" <> :binary.copy(<<0>>, 2_000))}])

      note = await_update("agent_message_chunk")["params"]["update"]["content"]["text"]
      assert note =~ "no transcription route"
      assert await_response(3)["result"]["stopReason"] == "end_turn"
    end
  end

  describe "a malformed block" do
    test "is the client's error, answered as one", %{server: server, project: project} do
      session_id = open_session(server, project)
      prompt(server, 3, session_id, [%{"type" => "image", "mimeType" => "image/png"}])

      error = await_response(3)["error"]
      assert error["code"] == -32_602
      assert error["message"] =~ "missing the field"
    end
  end
end
