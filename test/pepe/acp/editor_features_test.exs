defmodule Pepe.ACP.EditorFeaturesTest do
  @moduledoc """
  What an editor can do beyond sending prompts: authenticate, pick a model or a mode,
  type a slash command, and watch the plan and the token meter, all over real JSON-RPC
  against a real `Pepe.ACP.Server`, with a mock model that says what it was asked.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A model that can be told what to do by a word in the prompt: MAKEPLAN keeps a plan,
  # WRITEFILE writes out.txt, anything else is answered with a line. Every request is
  # reported to the test, so "the model was never called" can be asserted.
  defmodule FeaturePlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(pid, {:llm, request["messages"]})
      answer(conn, request["stream"] == true, decide(request["messages"]))
    end

    defp decide(messages) do
      prompt = messages |> Enum.filter(&(&1["role"] == "user")) |> Enum.map_join(" ", &to_string(&1["content"]))

      cond do
        List.last(messages)["role"] == "tool" ->
          {:text, "Done."}

        prompt =~ "MAKEPLAN" ->
          {:tool, "update_plan", %{"steps" => [%{"title" => "Read", "status" => "done"}, %{"title" => "Fix", "status" => "in_progress"}]}}

        prompt =~ "WRITEFILE" ->
          {:tool, "write_file", %{"path" => "out.txt", "content" => "hi"}}

        true ->
          {:text, "Hello from Pepe."}
      end
    end

    defp usage, do: %{"prompt_tokens" => 1_000, "completion_tokens" => 50, "total_tokens" => 1_050}

    defp call_of(name, args),
      do: [%{"id" => "call_1", "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}]

    defp answer(conn, false, decision) do
      {message, reason} =
        case decision do
          {:text, text} -> {%{"role" => "assistant", "content" => text}, "stop"}
          {:tool, name, args} -> {%{"role" => "assistant", "content" => nil, "tool_calls" => call_of(name, args)}, "tool_calls"}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => reason}], "usage" => usage()}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp answer(conn, true, decision) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      {delta, reason} =
        case decision do
          {:text, text} -> {%{"content" => text}, "stop"}
          {:tool, name, args} -> {%{"tool_calls" => call_of(name, args)}, "tool_calls"}
        end

      frames = [
        %{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]},
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]},
        %{"choices" => [], "usage" => usage()}
      ]

      Enum.each(frames, fn f -> {:ok, _} = chunk(conn, "data: #{Jason.encode!(f)}\n\n") end)
      {:ok, _} = chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_features_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    # Beside Pepe's home, not inside it: the home is a sensitive path no mode answers for.
    project = Path.join(System.tmp_dir!(), "pepe_acp_features_project_#{System.unique_integer([:positive])}")
    File.mkdir_p!(project)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      File.rm_rf(project)
    end)

    # Registered last so it runs first: a session still open must be stopped while the
    # config it runs against still exists. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    {:ok, home: home, project: project}
  end

  # Two model connections and an agent that may plan and write files without being asked
  # to authorize the tool itself (the ACP *mode* is what the writing tests exercise).
  defp with_models do
    {:ok, llm} = Bandit.start_link(plug: {FeaturePlug, self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)
    on_exit(fn -> Process.exit(llm, :normal) end)

    url = "http://localhost:#{port}"
    Config.put_model(%Model{name: "mock", base_url: url, api_key: "k", model: "mock-model", context_window: 10_000})
    Config.put_model(%Model{name: "alt", base_url: url, api_key: "k", model: "alt-model"})

    Config.put_agent(%Agent{
      name: "editor",
      model: "mock",
      tools: ["update_plan", "write_file"],
      auto_approve: ["update_plan"],
      max_iterations: 4
    })
  end

  defp connect(tag \\ :conn, agent \\ "editor") do
    test = self()
    writer = fn json -> send(test, {:out, tag, Jason.decode!(json)}) end
    server = start_supervised!(Supervisor.child_spec({Server, writer: writer, agent: agent}, id: tag))
    {server, tag}
  end

  defp call({server, tag}, id, method, params) do
    Server.handle_line(server, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}))
    collect(tag, id, [])
  end

  defp collect(tag, id, acc) do
    receive do
      {:out, ^tag, %{"id" => ^id} = message} when not is_map_key(message, "method") -> {Enum.reverse(acc), message}
      {:out, ^tag, message} -> collect(tag, id, [message | acc])
    after
      5_000 -> flunk("no response to request #{id}")
    end
  end

  defp initialized do
    conn = connect()
    {_, %{"result" => init}} = call(conn, 1, "initialize", %{"protocolVersion" => 1})
    {conn, init}
  end

  defp open(conn, cwd) do
    {_, %{"result" => result}} = call(conn, 2, "session/new", %{"cwd" => cwd, "mcpServers" => []})
    result
  end

  defp prompt(conn, session_id, text, id \\ 3) do
    call(conn, id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})
  end

  defp updates(notifications, kind) do
    for %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => ^kind} = update}} <- notifications, do: update
  end

  defp said(notifications) do
    notifications |> updates("agent_message_chunk") |> Enum.map_join("", & &1["content"]["text"])
  end

  defp llm_called?, do: receive(do: ({:llm, _} -> true), after: (100 -> false))

  describe "authentication" do
    test "the handshake offers the configured-credentials method once Pepe can answer, and setup always" do
      with_models()
      {_conn, init} = initialized()

      assert [config, setup] = init["authMethods"]
      assert config["id"] == "pepe-config"
      assert %{"id" => "pepe-setup", "type" => "terminal", "args" => ["--setup"]} = setup
    end

    test "authenticate succeeds for an offered method when the agent can answer, and refuses one it never offered" do
      with_models()
      {conn, _init} = initialized()

      assert {_, %{"result" => %{}}} = call(conn, 10, "authenticate", %{"methodId" => "pepe-config"})
      assert {_, %{"error" => %{"code" => -32_602}}} = call(conn, 11, "authenticate", %{"methodId" => "oauth"})
    end

    test "an agent with no usable model offers only setup, and both authenticate and session/new say auth_required" do
      Config.put_agent(%Agent{name: "editor", model: "ghost", tools: [], max_iterations: 2})
      {conn, init} = initialized()

      assert [%{"id" => "pepe-setup"}] = init["authMethods"]

      assert {_, %{"error" => %{"code" => -32_000, "message" => message}}} = call(conn, 10, "authenticate", %{"methodId" => "pepe-setup"})
      assert message =~ "no usable model"

      assert {_, %{"error" => %{"code" => -32_000}}} = call(conn, 11, "session/new", %{"cwd" => "/work", "mcpServers" => []})
    end

    test "an unknown agent name is auth_required too, naming the agent" do
      {conn, _init} = initialized_for("nobody")

      assert {_, %{"error" => %{"code" => -32_000, "message" => message}}} =
               call(conn, 10, "session/new", %{"cwd" => "/work", "mcpServers" => []})

      assert message =~ "nobody"
    end

    defp initialized_for(agent) do
      conn = connect(:named, agent)
      {_, %{"result" => init}} = call(conn, 1, "initialize", %{"protocolVersion" => 1})
      {conn, init}
    end
  end

  describe "session modes and model choice" do
    test "session/new reports the models, the modes and the config options, and the commands follow", %{project: project} do
      with_models()
      {{_server, tag} = conn, _init} = initialized()

      result = open(conn, project)

      assert %{"currentModeId" => "default", "availableModes" => modes} = result["modes"]
      assert Enum.map(modes, & &1["id"]) == ["default", "accept_edits", "dont_ask"]
      assert %{"currentModelId" => "mock", "availableModels" => models} = result["models"]
      assert Enum.map(models, & &1["modelId"]) == ["alt", "mock"]
      assert [%{"id" => "model", "currentValue" => "mock"}, %{"id" => "mode", "currentValue" => "default"}] = result["configOptions"]

      assert_receive {:out, ^tag,
                      %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = update}}}

      assert "rewind" in Enum.map(update["availableCommands"], & &1["name"])
    end

    test "set_mode changes the mode, tells the editor, and refuses one that does not exist", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      {notes, response} = call(conn, 10, "session/set_mode", %{"sessionId" => id, "modeId" => "accept_edits"})

      assert response["result"] == %{}
      assert [%{"currentModeId" => "accept_edits"}] = updates(notes, "current_mode_update")
      assert {_, %{"error" => %{"code" => -32_602}}} = call(conn, 11, "session/set_mode", %{"sessionId" => id, "modeId" => "sudo"})

      assert {_, %{"error" => %{"code" => -32_602}}} =
               call(conn, 12, "session/set_mode", %{"sessionId" => "sess_nope", "modeId" => "default"})
    end

    test "set_config_option changes the mode or the model and answers with the full option list", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      {_, %{"result" => %{"configOptions" => options}}} =
        call(conn, 10, "session/set_config_option", %{"sessionId" => id, "configId" => "mode", "value" => "dont_ask"})

      assert Enum.find(options, &(&1["id"] == "mode"))["currentValue"] == "dont_ask"

      {_, %{"result" => %{"configOptions" => options}}} =
        call(conn, 11, "session/set_config_option", %{"sessionId" => id, "configId" => "model", "value" => "alt"})

      assert Enum.find(options, &(&1["id"] == "model"))["currentValue"] == "alt"

      assert {_, %{"error" => %{"code" => -32_602}}} =
               call(conn, 12, "session/set_config_option", %{"sessionId" => id, "configId" => "mode", "value" => "sudo"})

      assert {_, %{"error" => %{"code" => -32_602}}} =
               call(conn, 13, "session/set_config_option", %{"sessionId" => id, "configId" => "model", "value" => "ghost"})

      assert {_, %{"error" => %{"code" => -32_602}}} =
               call(conn, 14, "session/set_config_option", %{"sessionId" => id, "configId" => "volume", "value" => "11"})
    end

    test "session/set_model switches the model for this conversation only", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      {_, %{"result" => %{}}} = call(conn, 10, "session/set_model", %{"sessionId" => id, "modelId" => "alt"})

      # The new option list is announced right after the answer.
      assert_receive {:out, :conn,
                      %{
                        "method" => "session/update",
                        "params" => %{"update" => %{"sessionUpdate" => "config_option_update", "configOptions" => options}}
                      }}

      assert Enum.find(options, &(&1["id"] == "model"))["currentValue"] == "alt"
      assert Config.get_agent("editor").model == "mock"
      assert {_, %{"error" => %{"code" => -32_602}}} = call(conn, 11, "session/set_model", %{"sessionId" => id, "modelId" => "ghost"})
    end

    test "accept_edits lets an edit inside the project through without a prompt, default asks", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      # In the default mode the write is put to the person, who refuses it.
      Server.handle_line(elem(conn, 0), prompt_line(id, "WRITEFILE please", 20))
      assert_receive {:out, :conn, %{"method" => "session/request_permission", "id" => ask_id}}, 5_000
      answer(conn, ask_id, "deny")
      {_, %{"result" => %{"stopReason" => "end_turn"}}} = collect(:conn, 20, [])
      refute File.exists?(Path.join(project, "out.txt"))

      # In accept_edits the same call goes straight through.
      {_, %{"result" => %{}}} = call(conn, 21, "session/set_mode", %{"sessionId" => id, "modeId" => "accept_edits"})
      {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "WRITEFILE please", 22)

      assert Enum.filter(notes, &(&1["method"] == "session/request_permission")) == []
      assert File.read!(Path.join(project, "out.txt")) == "hi"
      assert [%{"status" => "completed"}] = updates(notes, "tool_call_update")
    end

    test "/rewind puts back what a turn wrote in the project, and /retry files does it before asking again", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)
      {_, %{"result" => %{}}} = call(conn, 30, "session/set_mode", %{"sessionId" => id, "modeId" => "accept_edits"})

      File.write!(Path.join(project, "out.txt"), "before")
      {_notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "WRITEFILE please", 31)
      assert File.read!(Path.join(project, "out.txt")) == "hi"

      # The list says which turn changed a file.
      {notes, _} = prompt(conn, id, "/rewind", 32)
      assert said(notes) =~ "1. WRITEFILE please (1 file)"

      # Files only: the project goes back, the conversation stays.
      {notes, _} = prompt(conn, id, "/rewind 1 files", 33)
      assert said(notes) =~ "Put back 1 file: out.txt."
      assert said(notes) =~ "The conversation is unchanged."
      assert File.read!(Path.join(project, "out.txt")) == "before"

      # Retry with files: what it put back is announced before the same message goes out again,
      # and the model then writes the file again.
      {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "/retry files", 34)
      assert said(notes) =~ "The files of those turns were already put back."
      assert File.read!(Path.join(project, "out.txt")) == "hi"

      # Both: the write and the conversation go.
      {notes, _} = prompt(conn, id, "/rewind 1", 35)
      assert said(notes) =~ "Rewound 1 turn."
      assert said(notes) =~ "Put back 1 file: out.txt."
      assert File.read!(Path.join(project, "out.txt")) == "before"
    end

    test "/rewind chat and /undo leave the project's files and say so", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)
      {_, %{"result" => %{}}} = call(conn, 40, "session/set_mode", %{"sessionId" => id, "modeId" => "accept_edits"})

      {_notes, _} = prompt(conn, id, "WRITEFILE please", 41)
      {notes, _} = prompt(conn, id, "/undo", 42)

      assert said(notes) =~ "Undid your last message"
      assert said(notes) =~ "left as it is"
      assert File.read!(Path.join(project, "out.txt")) == "hi"
    end

    test "/retry with nothing said yet says so, and /rewind with junk says how to use it", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      {notes, _} = prompt(conn, id, "/retry", 50)
      assert said(notes) =~ "Nothing to retry yet."

      {notes, _} = prompt(conn, id, "/rewind banana", 51)
      assert said(notes) =~ "Usage: /rewind N"
    end

    defp prompt_line(session_id, text, id) do
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "session/prompt",
        "params" => %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]}
      })
    end

    defp answer({server, _tag}, request_id, option_id) do
      Server.handle_line(
        server,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
        })
      )
    end
  end

  describe "slash commands" do
    setup %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)
      {:ok, conn: conn, id: id}
    end

    test "/help is answered on the spot and never reaches the model", %{conn: conn, id: id} do
      {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "/help")

      assert said(notes) =~ "Commands:"
      assert said(notes) =~ "/rewind <N [chat|files]>"
      assert said(notes) =~ "/retry <files"
      refute llm_called?()
    end

    test "/status and /version report what they say they do", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/status", 4)
      assert said(notes) =~ "Agent: editor"
      assert said(notes) =~ "Turns: 0"

      {notes, _} = prompt(conn, id, "/version", 5)
      assert said(notes) =~ "Pepe v"
      refute llm_called?()
    end

    test "/models lists the choices and /model NAME switches this conversation", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/models", 4)
      assert said(notes) =~ "- alt (alt-model)"
      assert said(notes) =~ "- mock (mock-model)"

      {notes, _} = prompt(conn, id, "/model alt", 5)
      assert said(notes) =~ "Model set to alt"

      {notes, _} = prompt(conn, id, "/model nonsense", 6)
      assert said(notes) =~ "Unknown model: nonsense"

      {notes, _} = prompt(conn, id, "/model a b c", 7)
      assert said(notes) =~ "Usage: /model"
      refute llm_called?()
    end

    test "/context says so before any request, and reads the window after one", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/context", 4)
      assert said(notes) =~ "No request has been made yet"
      assert said(notes) =~ "Context window: 10000 tokens"

      {_notes, _} = prompt(conn, id, "a real question", 5)
      {notes, _} = prompt(conn, id, "/context", 6)
      assert said(notes) =~ "Last request: ~1050 tokens (10.5%)"
    end

    test "/rewind and /undo work on the conversation and explain themselves", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/rewind nonsense", 4)
      assert said(notes) =~ "Usage: /rewind N"

      {notes, _} = prompt(conn, id, "/rewind", 5)
      assert said(notes) =~ "Nothing to rewind yet"

      {_notes, _} = prompt(conn, id, "first question", 6)

      # A bare /rewind lists the turns to pick from instead of guessing.
      {notes, _} = prompt(conn, id, "/rewind", 7)
      assert said(notes) =~ "Recent turns, newest first:"
      assert said(notes) =~ "1. first question"
      assert said(notes) =~ "/rewind N chat"

      {notes, _} = prompt(conn, id, "/rewind 1", 8)
      assert said(notes) =~ "Rewound 1 turn"

      {_notes, _} = prompt(conn, id, "another question", 9)
      {notes, _} = prompt(conn, id, "/undo", 10)
      assert said(notes) =~ "Undid your last message"
    end

    test "/new starts over and /tools lists what the agent holds", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/new", 4)
      assert said(notes) =~ "New conversation started"

      {notes, _} = prompt(conn, id, "/tools", 5)
      assert said(notes) =~ "Available tools"
      assert said(notes) =~ "- update_plan"
      assert said(notes) =~ "- write_file"
    end

    test "/steer and /queue need a message, and with nothing running they simply become the next prompt", %{conn: conn, id: id} do
      {notes, _} = prompt(conn, id, "/steer", 4)
      assert said(notes) =~ "Usage: /steer"

      {notes, _} = prompt(conn, id, "/queue", 5)
      assert said(notes) =~ "Usage: /queue"
      refute llm_called?()

      {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "/queue what is up", 6)
      assert said(notes) =~ "Hello from Pepe."
      assert llm_called?()
    end

    test "a slash that is not one of our commands is an ordinary message for the model", %{conn: conn, id: id} do
      {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(conn, id, "/etc/hosts is unreadable", 4)

      assert said(notes) =~ "Hello from Pepe."
      assert llm_called?()
    end

    test "a prompt with an attachment is never read as a command", %{conn: conn, id: id} do
      blocks = [%{"type" => "text", "text" => "/new"}, %{"type" => "text", "text" => "and more"}]
      {notes, _} = call(conn, 4, "session/prompt", %{"sessionId" => id, "prompt" => blocks})

      assert said(notes) =~ "Hello from Pepe."
      assert llm_called?()
    end
  end

  describe "the plan and the token meter" do
    test "update_plan becomes an ACP plan, and usage becomes a meter and a total", %{project: project} do
      with_models()
      {conn, _} = initialized()
      %{"sessionId" => id} = open(conn, project)

      {notes, %{"result" => result}} = prompt(conn, id, "MAKEPLAN now")

      assert [plan] = updates(notes, "plan")
      assert [%{"content" => "Read", "status" => "completed"}, %{"content" => "Fix", "status" => "in_progress"}] = plan["entries"]

      meters = updates(notes, "usage_update")
      assert [%{"used" => 1_050, "size" => 10_000}, _second] = meters

      # Two model calls (the tool call, then the answer), each of 1,000 in and 50 out.
      assert result["usage"] == %{"inputTokens" => 2_000, "outputTokens" => 100, "totalTokens" => 2_100}
      assert result["stopReason"] == "end_turn"
    end
  end
end
