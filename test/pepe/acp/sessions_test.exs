defmodule Pepe.ACP.SessionsTest do
  @moduledoc """
  Editor conversations that outlive the connection: `session/list`, `session/load`,
  `session/resume` and `session/fork`, the store behind them (`Pepe.ACP.Sessions`) and the
  transcript replay (`Pepe.ACP.Replay`).

  Two connections are two `Pepe.ACP.Server`s. Inside one VM they share the session
  registry, so where a test needs the conversation to come back from DISK (as it does
  when a second `pepe acp` process opens it) it stops the live session process first.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Replay
  alias Pepe.ACP.Server
  alias Pepe.ACP.Sessions
  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Agent.SessionTitles
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Answers every request with one line, and tells the test what it was asked.
  defmodule AnswerPlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(pid, {:llm, request["messages"]})
      if request["stream"] == true, do: stream(conn), else: json(conn)
    end

    defp json(conn) do
      payload = %{
        "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "Hello from Pepe."}, "finish_reason" => "stop"}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp stream(conn) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      chunks = [
        "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Hello from Pepe."}, "finish_reason" => nil}]})}\n\n",
        "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})}\n\n",
        "data: [DONE]\n\n"
      ]

      Enum.each(chunks, fn c -> {:ok, _} = chunk(conn, c) end)
      conn
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_sessions_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    prev_flag = Application.get_env(:pepe, :acp_persist_sessions)
    Application.put_env(:pepe, :acp_persist_sessions, true)

    {:ok, llm} = Bandit.start_link(plug: {AnswerPlug, self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "editor", model: "mock", tools: [], max_iterations: 3})
    Config.put_agent(%Agent{name: "other", model: "mock", tools: [], max_iterations: 3})

    on_exit(fn ->
      Process.exit(llm, :normal)

      if prev_flag == nil,
        do: Application.delete_env(:pepe, :acp_persist_sessions),
        else: Application.put_env(:pepe, :acp_persist_sessions, prev_flag)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs first: a session still open must be stopped while the
    # config it runs against still exists. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    {:ok, home: home}
  end

  ###
  ### helpers
  ###

  defp connect(tag, agent \\ "editor") do
    test = self()
    writer = fn json -> send(test, {:out, tag, Jason.decode!(json)}) end
    server = start_supervised!(Supervisor.child_spec({Server, writer: writer, agent: agent}, id: tag))
    {_notifications, %{"result" => _}} = call(server, tag, 1, "initialize", %{"protocolVersion" => 1})
    {server, tag}
  end

  # One request, and everything the server wrote up to and including its response.
  defp call({server, tag}, id, method, params), do: call(server, tag, id, method, params)

  defp call(server, tag, id, method, params) do
    Server.handle_line(server, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}))
    collect(tag, id, [])
  end

  defp collect(tag, id, acc) do
    receive do
      {:out, ^tag, %{"id" => ^id} = message} when not is_map_key(message, "method") -> {Enum.reverse(acc), message}
      {:out, ^tag, message} -> collect(tag, id, [message | acc])
    after
      5_000 -> flunk("no response to request #{id} on connection #{inspect(tag)}")
    end
  end

  defp kinds(notifications) do
    for %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => kind}}} <- notifications, do: kind
  end

  defp updates(notifications, kind) do
    for %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => ^kind} = update}} <- notifications, do: update
  end

  defp new_session(conn, cwd \\ "/work/project") do
    {_, %{"result" => %{"sessionId" => id}}} = call(conn, 2, "session/new", %{"cwd" => cwd, "mcpServers" => []})
    id
  end

  defp ask(conn, session_id, text, id \\ 3) do
    call(conn, id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})
  end

  defp acp_dir, do: Path.join([Config.home(), "data", "acp_sessions"])

  # A saved session, written the way a finished `pepe acp` run leaves it.
  defp save_session(opts) do
    id = opts[:id] || Sessions.generate_id()
    File.mkdir_p!(acp_dir())

    meta = %{
      "id" => id,
      "cwd" => opts[:cwd] || "/work/project",
      "agent" => Keyword.get(opts, :agent, "editor"),
      "created_at" => opts[:updated_at] || Sessions.now(),
      "updated_at" => opts[:updated_at] || Sessions.now()
    }

    File.write!(Path.join(acp_dir(), id <> ".json"), Jason.encode!(meta))
    messages = opts[:messages] || [Message.system("you are editor"), Message.user("earlier question"), Message.assistant("earlier answer")]
    SessionPersistence.save(Sessions.key(id), meta["agent"] || "editor", messages)
    id
  end

  # An ISO timestamp `seconds` in the past. Fixed calendar dates would drift past the
  # retention window as the calendar moves and get swept by the connection's own prune.
  defp ago(seconds), do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  defp drain_llm, do: receive(do: ({:llm, _} -> drain_llm()), after: (50 -> :ok))

  defp last_llm_messages do
    receive do
      {:llm, messages} ->
        receive do
          {:llm, _newer} = newer ->
            send(self(), newer)
            last_llm_messages()
        after
          0 -> messages
        end
    after
      2_000 -> flunk("the model was never called")
    end
  end

  ###
  ### ids
  ###

  describe "session ids" do
    test "are unguessable and never repeat, unlike a per-connection counter" do
      ids = for _ <- 1..200, do: Sessions.generate_id()

      assert length(Enum.uniq(ids)) == 200
      assert Enum.all?(ids, &Sessions.valid_id?/1)
      assert Enum.all?(ids, &(byte_size(&1) == 29))
    end

    test "an id from the client that could reach outside the store is not an id at all" do
      for bad <- ["../../etc/passwd", "sess_../x", "sess_short", "sess_" <> String.duplicate("a", 200), "", nil, 5] do
        refute Sessions.valid_id?(bad)
      end
    end

    test "a hostile sessionId gets the same answer as an unknown one, and touches nothing" do
      conn = connect(:a)

      for bad <- ["../../etc/passwd", "sess_../../x", 42] do
        {_, response} = call(conn, 10, "session/load", %{"sessionId" => bad, "cwd" => "/work/project", "mcpServers" => []})
        assert response["error"]["code"] == -32_602
        assert response["error"]["message"] =~ "unknown `sessionId`"
      end
    end
  end

  ###
  ### surviving the connection
  ###

  describe "a conversation that outlives its connection" do
    test "comes back on session/load with its history replayed, and carries on from it" do
      {server_a, _} = conn_a = connect(:a)
      sid = new_session(conn_a)
      {_, %{"result" => %{"stopReason" => "end_turn"}}} = ask(conn_a, sid, "remember the blue key")

      key = Sessions.key(sid)
      assert {:ok, "default/editor", saved, _pii, nil} = SessionPersistence.load(key)
      assert Enum.any?(saved, &(&1["content"] == "remember the blue key"))

      # The editor closes: the connection lets go, the conversation stays.
      Server.close(server_a)
      refute File.exists?(Path.join(acp_dir(), sid <> ".lock"))
      assert File.exists?(Path.join(acp_dir(), sid <> ".json"))
      SessionSupervisor.terminate(key)

      conn_b = connect(:b)
      {notifications, response} = call(conn_b, 20, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})

      assert response["result"] == %{}
      # The transcript arrives BEFORE the response: a client builds its panel from it.
      assert kinds(notifications) == ["user_message_chunk", "agent_message_chunk", "session_info_update"]
      assert [%{"content" => %{"text" => "remember the blue key"}}] = updates(notifications, "user_message_chunk")
      assert [%{"content" => %{"text" => "Hello from Pepe."}}] = updates(notifications, "agent_message_chunk")

      drain_llm()
      {_, %{"result" => %{"stopReason" => "end_turn"}}} = ask(conn_b, sid, "what was the key?", 21)
      assert Enum.any?(last_llm_messages(), &(&1["content"] == "remember the blue key"))
    end

    test "a session is not recorded until it has had a turn" do
      conn = connect(:a)
      sid = new_session(conn)

      {_, %{"result" => %{"sessions" => []}}} = call(conn, 4, "session/list", %{})
      refute File.exists?(Path.join(acp_dir(), sid <> ".json"))

      ask(conn, sid, "hi")
      {_, %{"result" => %{"sessions" => [%{"sessionId" => ^sid}]}}} = call(conn, 5, "session/list", %{})
    end

    test "session/resume picks the conversation up without replaying it" do
      sid = save_session([])
      conn = connect(:a)

      {notifications, response} = call(conn, 20, "session/resume", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})

      assert response["result"] == %{}
      assert kinds(notifications) == ["session_info_update"]

      {_, %{"result" => %{"stopReason" => "end_turn"}}} = ask(conn, sid, "and now?")
      assert Enum.any?(last_llm_messages(), &(&1["content"] == "earlier question"))
    end

    test "loading points the session at the directory the editor has open now" do
      sid = save_session(cwd: "/work/old-place")
      conn = connect(:a)

      call(conn, 20, "session/load", %{"sessionId" => sid, "cwd" => "/work/new-place", "mcpServers" => []})

      assert {:ok, %{"cwd" => "/work/new-place"}} = Sessions.fetch(sid)
    end

    test "an unknown session is an error, never a quietly created new one" do
      conn = connect(:a)
      {_, response} = call(conn, 20, "session/load", %{"sessionId" => Sessions.generate_id(), "cwd" => "/work/project", "mcpServers" => []})

      {_, resumed} =
        call(conn, 21, "session/resume", %{"sessionId" => Sessions.generate_id(), "cwd" => "/work/project", "mcpServers" => []})

      assert response["error"]["code"] == -32_602
      assert resumed["error"]["code"] == -32_602
    end

    test "a relative cwd and client MCP servers are refused on load like they are on new" do
      sid = save_session([])
      conn = connect(:a)

      {_, relative} = call(conn, 20, "session/load", %{"sessionId" => sid, "cwd" => "relative", "mcpServers" => []})
      assert relative["error"]["message"] =~ "absolute"

      {_, mcp} = call(conn, 21, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => [%{"name" => "x"}]})
      assert mcp["error"]["message"] =~ "pepe mcp add"
    end
  end

  ###
  ### listing
  ###

  describe "session/list" do
    test "lists newest first, with a title from what was asked when nothing named it" do
      old_at = ago(2 * 86_400)
      new_at = ago(86_400)
      old = save_session(updated_at: old_at, messages: [Message.system("s"), Message.user("  first    thing\nwe asked  ")])
      new = save_session(updated_at: new_at, messages: [Message.system("s"), Message.user("second thing")])
      SessionTitles.set(Sessions.key(new), "A given name")

      {_, %{"result" => %{"sessions" => sessions} = result}} = call(connect(:a), 4, "session/list", %{})

      assert [%{"sessionId" => ^new, "title" => "A given name"}, %{"sessionId" => ^old, "title" => "first thing we asked"}] = sessions
      assert hd(sessions)["updatedAt"] == new_at
      assert hd(sessions)["cwd"] == "/work/project"
      refute Map.has_key?(result, "nextCursor")
    end

    test "filters by cwd" do
      here = save_session(cwd: "/work/here")
      _elsewhere = save_session(cwd: "/work/elsewhere")

      {_, %{"result" => %{"sessions" => sessions}}} = call(connect(:a), 4, "session/list", %{"cwd" => "/work/here"})

      assert [%{"sessionId" => ^here}] = sessions
    end

    test "pages with an opaque cursor, and a cursor it did not issue is an error" do
      ids = for n <- 1..55, do: save_session(updated_at: ago(n * 60))
      conn = connect(:a)

      {_, %{"result" => %{"sessions" => first, "nextCursor" => cursor}}} = call(conn, 4, "session/list", %{})
      {_, %{"result" => %{"sessions" => second} = last}} = call(conn, 5, "session/list", %{"cursor" => cursor})

      assert length(first) == 50
      assert length(second) == 5
      refute Map.has_key?(last, "nextCursor")
      assert Enum.sort(Enum.map(first ++ second, & &1["sessionId"])) == Enum.sort(ids)

      {_, bad} = call(conn, 6, "session/list", %{"cursor" => "not-a-cursor"})
      assert bad["error"]["code"] == -32_602
    end

    test "only shows the conversations of the agent this connection is bound to, and refuses the others" do
      mine = save_session(agent: "editor")
      theirs = save_session(agent: "other")
      conn = connect(:a)

      {_, %{"result" => %{"sessions" => sessions}}} = call(conn, 4, "session/list", %{})
      assert [%{"sessionId" => ^mine}] = sessions

      {_, response} = call(conn, 5, "session/load", %{"sessionId" => theirs, "cwd" => "/work/project", "mcpServers" => []})
      assert response["error"]["message"] =~ "belongs to agent `default/other`"
      assert response["error"]["message"] =~ "pepe acp default/other"
    end

    test "a session whose agent has since been deleted cannot be loaded, and says why" do
      sid = save_session(agent: "editor")

      File.write!(
        Path.join(acp_dir(), sid <> ".json"),
        Jason.encode!(%{"id" => sid, "cwd" => "/w", "agent" => "gone", "updated_at" => Sessions.now()})
      )

      {_, response} = call(connect(:a), 5, "session/load", %{"sessionId" => sid, "cwd" => "/w", "mcpServers" => []})

      assert response["error"]["message"] =~ "no longer exists"
    end
  end

  ###
  ### one process at a time
  ###

  describe "the same session opened twice" do
    test "a process that has it open makes the second one wait, and points at session/fork" do
      sid = save_session([])
      # pid 1 always exists (and is not ours): the lock is held by someone alive.
      File.write!(Path.join(acp_dir(), sid <> ".lock"), "1")

      {_, response} = call(connect(:a), 20, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})

      assert response["error"]["code"] == -32_600
      assert response["error"]["message"] =~ "pid 1"
      assert response["error"]["message"] =~ "session/fork"
    end

    test "a lock left by a process that died is taken over" do
      sid = save_session([])
      File.write!(Path.join(acp_dir(), sid <> ".lock"), "2147483646")

      {_, response} = call(connect(:a), 20, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})

      assert response["result"] == %{}
      assert File.read!(Path.join(acp_dir(), sid <> ".lock")) == System.pid()
    end

    test "opening it again on the same connection is not a conflict" do
      sid = save_session([])
      conn = connect(:a)

      {_, first} = call(conn, 20, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})
      {_, second} = call(conn, 21, "session/load", %{"sessionId" => sid, "cwd" => "/work/project", "mcpServers" => []})

      assert first["result"] == %{}
      assert second["result"] == %{}
    end

    test "closing the connection gives the lock back, and only ours" do
      mine = save_session([])
      held = save_session([])
      File.write!(Path.join(acp_dir(), held <> ".lock"), "1")
      {server, _} = conn = connect(:a)
      call(conn, 20, "session/load", %{"sessionId" => mine, "cwd" => "/work/project", "mcpServers" => []})
      assert File.exists?(Path.join(acp_dir(), mine <> ".lock"))

      Server.close(server)

      refute File.exists?(Path.join(acp_dir(), mine <> ".lock"))
      assert File.exists?(Path.join(acp_dir(), held <> ".lock"))
    end
  end

  ###
  ### fork
  ###

  describe "session/fork" do
    test "starts a new conversation from a copy of the saved one, leaving the original alone" do
      source = save_session([])
      conn = connect(:a)

      {_, %{"result" => %{"sessionId" => copy}}} =
        call(conn, 20, "session/fork", %{"sessionId" => source, "cwd" => "/work/branch", "mcpServers" => []})

      assert copy != source
      assert Sessions.valid_id?(copy)
      assert {:ok, "editor", [_system, %{"content" => "earlier question"}, _answer], _, _} = SessionPersistence.load(Sessions.key(copy))
      assert {:ok, %{"cwd" => "/work/branch"}} = Sessions.fetch(copy)

      # They evolve independently.
      {_, %{"result" => %{"stopReason" => "end_turn"}}} = ask(conn, copy, "only on the branch")
      {:ok, _, original, _, _} = SessionPersistence.load(Sessions.key(source))
      refute Enum.any?(original, &(&1["content"] == "only on the branch"))

      {_, %{"result" => %{"sessions" => sessions}}} = call(conn, 21, "session/list", %{})
      assert Enum.sort(Enum.map(sessions, & &1["sessionId"])) == Enum.sort([source, copy])
    end

    test "forks a session that is open on this connection from its live state" do
      conn = connect(:a)
      source = new_session(conn)
      ask(conn, source, "the live question")

      {_, %{"result" => %{"sessionId" => copy}}} =
        call(conn, 20, "session/fork", %{"sessionId" => source, "cwd" => "/work/branch", "mcpServers" => []})

      assert {:ok, _, messages, _, _} = SessionPersistence.load(Sessions.key(copy))
      assert Enum.any?(messages, &(&1["content"] == "the live question"))
    end

    test "can copy a session another process has open: it only reads" do
      source = save_session([])
      File.write!(Path.join(acp_dir(), source <> ".lock"), "1")

      {_, %{"result" => %{"sessionId" => copy}}} =
        call(connect(:a), 20, "session/fork", %{"sessionId" => source, "cwd" => "/w", "mcpServers" => []})

      assert Sessions.valid_id?(copy)
    end

    test "an unknown source is an error" do
      {_, response} = call(connect(:a), 20, "session/fork", %{"sessionId" => Sessions.generate_id(), "cwd" => "/w", "mcpServers" => []})
      assert response["error"]["code"] == -32_602
    end
  end

  ###
  ### keeping the editor's panel current
  ###

  describe "session_info_update" do
    test "a finished turn tells the editor the session was just used" do
      conn = connect(:a)
      sid = new_session(conn)

      {notifications, _} = ask(conn, sid, "hello")

      assert [%{"updatedAt" => updated_at}] = Enum.filter(updates(notifications, "session_info_update"), &Map.has_key?(&1, "updatedAt"))
      assert {:ok, %{"updated_at" => ^updated_at}} = Sessions.fetch(sid)
    end

    test "a generated title reaches the editor as soon as the session is named" do
      conn = connect(:a)
      sid = new_session(conn)

      Phoenix.PubSub.broadcast(Pepe.PubSub, "session:" <> Sessions.key(sid), {:titled, Sessions.key(sid), "Fixing the parser"})

      assert_receive {:out, :a,
                      %{
                        "method" => "session/update",
                        "params" => %{
                          "sessionId" => ^sid,
                          "update" => %{"sessionUpdate" => "session_info_update", "title" => "Fixing the parser"}
                        }
                      }},
                     2_000
    end
  end

  ###
  ### what stays out of other surfaces' way
  ###

  describe "isolation from the rest of Pepe" do
    test "boot-time restore does not re-spawn editor conversations, and leaves their files alone" do
      sid = save_session([])
      SessionPersistence.save("test:restore:1", "editor", [Message.system("s")])

      prev_env = Application.get_env(:pepe, :env)
      prev_persist = Application.get_env(:pepe, :persist_sessions)
      Application.put_env(:pepe, :env, :dev)
      Application.put_env(:pepe, :persist_sessions, true)

      on_exit(fn ->
        Application.put_env(:pepe, :env, prev_env)

        if prev_persist == nil,
          do: Application.delete_env(:pepe, :persist_sessions),
          else: Application.put_env(:pepe, :persist_sessions, prev_persist)
      end)

      SessionSupervisor.restore()

      assert [{_pid, _}] = Registry.lookup(Pepe.Agent.Registry, "test:restore:1")
      assert Registry.lookup(Pepe.Agent.Registry, Sessions.key(sid)) == []
      assert {:ok, _agent, _messages, _pii, _pending} = SessionPersistence.load(Sessions.key(sid))
    end

    test "a session file is written without the global persistence flag" do
      refute Application.get_env(:pepe, :persist_sessions)
      conn = connect(:a)
      sid = new_session(conn)
      ask(conn, sid, "hello")

      assert {:ok, "default/editor", [_ | _], _, nil} = SessionPersistence.load(Sessions.key(sid))
    end
  end

  ###
  ### retention
  ###

  describe "retention" do
    test "prune removes what is past 30 days, with its history and title, and keeps the rest" do
      stale = save_session(updated_at: "2020-01-01T00:00:00Z")
      fresh = save_session([])
      SessionTitles.set(Sessions.key(stale), "old title")

      Sessions.prune()

      assert :error = Sessions.fetch(stale)
      assert :error = SessionPersistence.load(Sessions.key(stale))
      assert SessionTitles.get(Sessions.key(stale)) == nil
      assert {:ok, _} = Sessions.fetch(fresh)
    end

    test "prune never touches a session another live process has open" do
      held = save_session(updated_at: "2020-01-01T00:00:00Z")
      File.write!(Path.join(acp_dir(), held <> ".lock"), "1")

      Sessions.prune()

      assert {:ok, _} = Sessions.fetch(held)
    end

    test "past 200 sessions the oldest go first" do
      ids = for n <- 1..205, do: save_session(updated_at: DateTime.utc_now() |> DateTime.add(-n, :second) |> DateTime.to_iso8601())

      Sessions.prune()

      kept = Enum.filter(ids, &match?({:ok, _}, Sessions.fetch(&1)))
      assert length(kept) == 200
      assert Enum.take(ids, 200) == kept
    end
  end

  ###
  ### the transcript
  ###

  describe "Replay.updates/1" do
    defp tool_call(id, name, args),
      do: %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}

    test "shows what was said and what was answered, never the system prompt" do
      messages = [Message.system("secret persona"), Message.user("hello"), Message.assistant("hi there")]

      assert [
               %{"sessionUpdate" => "user_message_chunk", "content" => %{"text" => "hello"}},
               %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => "hi there"}}
             ] = Replay.updates(messages)
    end

    test "drops Pepe's own notes, and keeps the words that came after one" do
      messages = [
        Message.user("<system-reminder>\nCurrent time: 2026-09-19\n</system-reminder>"),
        Message.user("<system-reminder>\nCurrent sender: Maria\n</system-reminder>\nplease deploy"),
        Message.user("<system-reminder>a compaction summary</system-reminder>")
      ]

      assert [%{"sessionUpdate" => "user_message_chunk", "content" => %{"text" => "please deploy"}}] = Replay.updates(messages)
    end

    test "pairs each tool call with its result, and marks an error as failed" do
      messages = [
        Message.user("check things"),
        Message.assistant_tool_calls("", [tool_call("c1", "read_file", %{"path" => "a"}), tool_call("c2", "bash", %{"command" => "false"})]),
        Message.tool_result("c1", "read_file", "contents"),
        Message.tool_result("c2", "bash", "Error: tool bash crashed: exit 1"),
        Message.assistant("done")
      ]

      updates = Replay.updates(messages)

      assert ["user_message_chunk", "tool_call", "tool_call", "tool_call_update", "tool_call_update", "agent_message_chunk"] ==
               Enum.map(updates, & &1["sessionUpdate"])

      [_, %{"toolCallId" => "c1"}, %{"toolCallId" => "c2"}, ok, failed | _] = updates
      assert %{"toolCallId" => "c1", "status" => "completed"} = ok
      assert %{"toolCallId" => "c2", "status" => "failed"} = failed
    end

    test "a call with no result on record is closed as failed, not left running forever" do
      messages = [Message.user("go"), Message.assistant_tool_calls("", [tool_call("lost", "bash", %{"command" => "sleep 100"})])]

      assert %{"toolCallId" => "lost", "status" => "failed"} = List.last(Replay.updates(messages))
    end

    test "cuts an output too long for a transcript" do
      messages = [
        Message.user("go"),
        Message.assistant_tool_calls("", [tool_call("c1", "bash", %{})]),
        Message.tool_result("c1", "bash", String.duplicate("x", 50_000))
      ]

      %{"content" => [%{"content" => %{"text" => text}}]} = List.last(Replay.updates(messages))
      assert String.length(text) < 9_000
      assert text =~ "output cut"
    end

    test "a multimodal user turn is shown as its text, with a marker where the attachment was" do
      messages = [
        Message.user([%{"type" => "text", "text" => "look at this"}, %{"type" => "image_url", "image_url" => %{"url" => "data:..."}}])
      ]

      assert [%{"content" => %{"text" => "look at this\n[image_url]"}}] = Replay.updates(messages)
    end

    test "an empty history is nothing to replay" do
      assert Replay.updates([]) == []
      assert Replay.updates([Message.system("only a prompt")]) == []
    end
  end
end
