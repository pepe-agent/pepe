defmodule Pepe.ACP.TurnLifecycleTest do
  @moduledoc """
  How a prompt turn starts, waits and ends when the editor does not behave: it cancels
  before the model was ever called, it sends a second prompt while one is running, it stops
  in the middle of a command, and something slow happens while other sessions on the same
  connection still need answering.

  The model here can be held mid-request, and the slow parts of a prompt (a transcription)
  are stubbed through `:acp_content_opts`, so every one of these waits on a message instead
  of a clock.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Answers every request; one whose last message says HOLD is not answered until the test
  # sends its handler `:release`, and every request is reported so the test can hold it.
  defmodule GatePlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      last = request["messages"] |> List.last() |> Map.get("content") |> to_string()

      send(pid, {:llm_request, self(), last})

      if last =~ "HOLD" do
        receive do
          :release -> :ok
        after
          30_000 -> :ok
        end
      end

      answer(conn, request["stream"] == true)
    end

    defp answer(conn, false) do
      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "Answer."}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp answer(conn, true) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      frames = [
        %{"choices" => [%{"index" => 0, "delta" => %{"content" => "Answer."}, "finish_reason" => nil}]},
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}
      ]

      # The editor may have cancelled while this request was held: a closed socket is fine.
      Enum.reduce_while(frames ++ [:done], conn, fn frame, conn ->
        data = if frame == :done, do: "[DONE]", else: Jason.encode!(frame)

        case chunk(conn, "data: #{data}\n\n") do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, llm} = Bandit.start_link(plug: {GatePlug, self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "editor", model: "mock", tools: [], max_iterations: 3})

    on_exit(fn ->
      Application.delete_env(:pepe, :acp_content_opts)
      Process.exit(llm, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs first: a session still open must be stopped while the
    # config it runs against still exists. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    test = self()
    writer = fn json -> send(test, {:out, Jason.decode!(json)}) end
    server = start_supervised!({Server, writer: writer, agent: "editor"})

    {_, %{"result" => _}} = call(server, 1, "initialize", %{"protocolVersion" => 1})
    {:ok, server: server}
  end

  defp send_request(server, id, method, params),
    do: Server.handle_line(server, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}))

  defp call(server, id, method, params) do
    send_request(server, id, method, params)
    collect(id, [])
  end

  defp collect(id, acc) do
    receive do
      {:out, %{"id" => ^id} = message} when not is_map_key(message, "method") -> {Enum.reverse(acc), message}
      {:out, message} -> collect(id, [message | acc])
    after
      5_000 -> flunk("no response to request #{id}")
    end
  end

  defp open(server) do
    {_, %{"result" => %{"sessionId" => id}}} = call(server, 2, "session/new", %{"cwd" => System.tmp_dir!(), "mcpServers" => []})
    id
  end

  defp send_prompt(server, id, session_id, text) do
    send_request(server, id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})
  end

  defp cancel(server, session_id),
    do:
      Server.handle_line(
        server,
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/cancel", "params" => %{"sessionId" => session_id}})
      )

  defp response(id, timeout \\ 5_000) do
    assert_receive {:out, %{"id" => ^id} = message}, timeout
    message
  end

  # The next agent message on `session_id` that contains `fragment`; earlier ones are skipped.
  defp agent_text(session_id, fragment) do
    receive do
      {:out,
       %{
         "method" => "session/update",
         "params" => %{"sessionId" => ^session_id, "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => text}}}
       }} ->
        if text =~ fragment, do: text, else: agent_text(session_id, fragment)
    after
      2_000 -> flunk("no agent message containing #{inspect(fragment)}")
    end
  end

  # An audio block whose transcription the test decides when to finish.
  defp slow_audio_prompt do
    test = self()

    Application.put_env(:pepe, :acp_content_opts,
      transcribe: fn _path ->
        send(test, {:transcribing, self()})

        receive do
          :go -> {:ok, "what the audio said"}
        end
      end
    )

    [%{"type" => "audio", "mimeType" => "audio/ogg", "data" => Base.encode64("OggS" <> :binary.copy(<<0>>, 32))}]
  end

  describe "cancelling before the model was ever called" do
    test "stops the turn, answers `cancelled`, and never calls (or bills) the model", %{server: server} do
      session_id = open(server)

      send_request(server, 10, "session/prompt", %{"sessionId" => session_id, "prompt" => slow_audio_prompt()})
      assert_receive {:transcribing, stub}, 5_000
      stub_ref = Process.monitor(stub)

      cancel(server, session_id)

      assert %{"result" => %{"stopReason" => "cancelled"}} = response(10)
      assert_receive {:DOWN, ^stub_ref, :process, ^stub, _}, 5_000
      refute_receive {:llm_request, _, _}, 300

      # The session is free again: the next prompt is not refused as "already in flight".
      send_prompt(server, 11, session_id, "still there?")
      assert %{"result" => %{"stopReason" => "end_turn"}} = response(11)
    end
  end

  describe "a slow prompt on one session" do
    test "does not keep the connection from answering another session's requests", %{server: server} do
      slow = open(server)
      other = open(server)

      send_request(server, 10, "session/prompt", %{"sessionId" => slow, "prompt" => slow_audio_prompt()})
      assert_receive {:transcribing, stub}, 5_000

      # With the transcription still running, an unrelated request is answered at once.
      send_request(server, 11, "session/set_mode", %{"sessionId" => other, "modeId" => "accept_edits"})
      assert %{"result" => %{}} = response(11, 1_000)

      send(stub, :go)
      assert %{"result" => %{"stopReason" => "end_turn"}} = response(10)
      assert_receive {:llm_request, _, prompt}
      assert prompt =~ "what the audio said"
    end

    test "says what could not be used before the answer starts, from the turn's own task", %{server: server} do
      session_id = open(server)
      Application.put_env(:pepe, :acp_content_opts, transcribe: fn _path -> :unavailable end)
      audio = [%{"type" => "audio", "mimeType" => "audio/ogg", "data" => Base.encode64("OggS" <> :binary.copy(<<0>>, 32))}]

      send_request(server, 10, "session/prompt", %{"sessionId" => session_id, "prompt" => audio})

      assert agent_text(session_id, "was not included") =~ "Note: The attached audio was not included: no transcription route is configured"
      assert %{"result" => %{"stopReason" => "end_turn"}} = response(10)
    end
  end

  describe "a prompt sent with /queue while a turn is running" do
    test "keeps its own request open and answers it with the queued turn's stop reason, once", %{server: server} do
      session_id = open(server)

      send_prompt(server, 20, session_id, "HOLD the first")
      assert_receive {:llm_request, first_handler, "HOLD the first"}, 5_000

      send_prompt(server, 21, session_id, "/queue the second")
      assert agent_text(session_id, "Queued") =~ "Queued for after the current turn. (1 waiting)"
      refute_receive {:out, %{"id" => 21}}, 300

      send(first_handler, :release)

      assert %{"result" => %{"stopReason" => "end_turn"}} = response(20)
      assert_receive {:llm_request, _, "the second"}, 5_000
      assert %{"result" => %{"stopReason" => "end_turn"}} = response(21)

      # One answer each, and nothing left over.
      refute_receive {:out, %{"id" => 20}}, 200
      refute_receive {:out, %{"id" => 21}}, 100
    end

    test "is answered `cancelled`, with everything else queued behind it, when the turn ahead is cancelled", %{server: server} do
      session_id = open(server)

      send_prompt(server, 30, session_id, "HOLD the first")
      assert_receive {:llm_request, first_handler, "HOLD the first"}, 5_000
      send_prompt(server, 31, session_id, "/queue never one")
      send_prompt(server, 32, session_id, "/queue never two")
      assert agent_text(session_id, "(1 waiting)")
      assert agent_text(session_id, "(2 waiting)")

      cancel(server, session_id)

      assert %{"result" => %{"stopReason" => "cancelled"}} = response(30)
      assert %{"result" => %{"stopReason" => "cancelled"}} = response(31)
      assert %{"result" => %{"stopReason" => "cancelled"}} = response(32)

      send(first_handler, :release)
      refute_receive {:llm_request, _, "never one"}, 300
      refute_receive {:llm_request, _, "never two"}, 100
    end
  end

  describe "a slash command that never comes back" do
    # `/undo` is a call into the session process; with that process suspended it just waits.
    defp hang_undo(server) do
      session_id = open(server)
      send_prompt(server, 40, session_id, "/status")
      assert %{"result" => %{"stopReason" => "end_turn"}} = response(40)

      [{session_pid, _}] = Registry.lookup(Pepe.Agent.Registry, "acp:" <> session_id)
      :ok = :sys.suspend(session_pid)
      on_exit(fn -> if Process.alive?(session_pid), do: :sys.resume(session_pid) end)

      send_prompt(server, 41, session_id, "/undo")
      task = wait_for_command(server)
      {session_id, task}
    end

    defp wait_for_command(server) do
      case :sys.get_state(server).commands |> Map.values() do
        [%{task: task}] ->
          task

        [] ->
          receive do
          after
            20 -> wait_for_command(server)
          end
      end
    end

    test "a command whose task is killed is answered, not left waiting forever", %{server: server} do
      {session_id, task} = hang_undo(server)

      Process.exit(task, :kill)

      assert %{"result" => %{"stopReason" => "end_turn"}} = response(41)
      assert agent_text(session_id, "/undo failed")
      assert :sys.get_state(server).commands == %{}
    end

    test "session/cancel ends a command that is still running, and answers it `cancelled`", %{server: server} do
      {session_id, task} = hang_undo(server)
      ref = Process.monitor(task)

      cancel(server, session_id)

      assert %{"result" => %{"stopReason" => "cancelled"}} = response(41)
      assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
      assert :sys.get_state(server).commands == %{}
    end
  end
end
