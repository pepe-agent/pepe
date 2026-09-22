defmodule Pepe.ACP.SkillCommandsTest do
  @moduledoc """
  Installed skills as an editor's slash commands: announced in `available_commands_update`
  the way the skills index offers them to the agent, and run as an ordinary turn.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Commands
  alias Pepe.ACP.Server
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Skills.Project
  alias Pepe.Skills.Settings

  defmodule EchoPlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(pid, {:llm, request["messages"]})

      answer(conn, request["stream"] == true)
    end

    defp usage, do: %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}

    defp answer(conn, false) do
      message = %{"role" => "assistant", "content" => "Hello from Pepe."}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}], "usage" => usage()}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp answer(conn, true) do
      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      frames = [
        %{"choices" => [%{"index" => 0, "delta" => %{"content" => "Hello from Pepe."}, "finish_reason" => nil}]},
        %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]},
        %{"choices" => [], "usage" => usage()}
      ]

      Enum.each(frames, fn frame -> {:ok, _} = chunk(conn, "data: #{Jason.encode!(frame)}\n\n") end)
      {:ok, _} = chunk(conn, "data: [DONE]\n\n")
      conn
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    project = Path.join(System.tmp_dir!(), "pepe_acp_skills_project_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(project, ".git"))

    {:ok, llm} = Bandit.start_link(plug: {EchoPlug, self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(llm)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "editor", model: "mock", tools: ["skill"], max_iterations: 4})
    Config.put_agent(%Agent{name: "bare", model: "mock", tools: ["bash"], max_iterations: 4})

    File.write!(Path.join([home, "skills", "ship-it.md"]), "---\nname: ship-it\ndescription: Use when shipping.\n---\n\nSteps.\n")

    on_exit(fn ->
      Process.exit(llm, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      File.rm_rf(project)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    {:ok, home: home, project: project}
  end

  defp connect(agent) do
    test = self()
    writer = fn json -> send(test, {:out, Jason.decode!(json)}) end
    server = start_supervised!({Server, writer: writer, agent: agent})
    {_, %{"result" => _}} = call(server, 1, "initialize", %{"protocolVersion" => 1})
    server
  end

  defp call(server, id, method, params) do
    Server.handle_line(server, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}))
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

  # Opens a session and returns its id with the commands the editor was told about (the
  # announcement follows the `session/new` response).
  defp open(server, cwd, id \\ 2) do
    {_, %{"result" => %{"sessionId" => session_id}}} = call(server, id, "session/new", %{"cwd" => cwd, "mcpServers" => []})

    assert_receive {:out,
                    %{
                      "method" => "session/update",
                      "params" => %{"sessionId" => ^session_id, "update" => %{"sessionUpdate" => "available_commands_update"} = update}
                    }}

    {session_id, update["availableCommands"]}
  end

  defp names(commands), do: Enum.map(commands, & &1["name"])

  defp prompt(server, id, session_id, text) do
    call(server, id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})
  end

  defp said(notes) do
    for %{"method" => "session/update", "params" => %{"update" => %{"sessionUpdate" => "agent_message_chunk"} = update}} <- notes,
        into: "",
        do: update["content"]["text"]
  end

  # What the model was sent as the user's words, or nil when it was never called.
  defp llm_prompt do
    receive do
      {:llm, messages} -> messages |> Enum.filter(&(&1["role"] == "user")) |> Enum.map_join("\n", &to_string(&1["content"]))
    after
      500 -> nil
    end
  end

  test "the skills an agent is offered are announced beside the built-in commands", %{project: project} do
    server = connect("editor")

    {_id, commands} = open(server, project)

    assert "rewind" in names(commands)
    assert "skill" in names(commands)
    assert %{"description" => "Use when shipping.", "input" => %{"hint" => _}} = Enum.find(commands, &(&1["name"] == "ship-it"))
  end

  test "a name that is a built-in command stays the built-in one", %{home: home, project: project} do
    File.write!(Path.join([home, "skills", "help.md"]), "---\nname: help\ndescription: Use when helping.\n---\n\nSteps.\n")
    server = connect("editor")

    {_id, commands} = open(server, project)

    assert [help] = Enum.filter(commands, &(&1["name"] == "help"))
    assert help["description"] == "List the available commands"
  end

  test "an agent without the skill tool is announced no skill", %{project: project} do
    server = connect("bare")

    {_id, commands} = open(server, project)

    refute "ship-it" in names(commands)
  end

  test "a skill switched off for the editor is no longer announced", %{project: project} do
    server = connect("editor")
    {_id, before} = open(server, project)
    assert "ship-it" in names(before)

    Settings.disable("ship-it", "acp")

    {_id, after_off} = open(server, project, 3)
    refute "ship-it" in names(after_off)
  end

  test "a skill runs by its own name, as a turn carrying the input", %{project: project} do
    server = connect("editor")
    {session_id, _} = open(server, project)

    {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(server, 3, session_id, "/ship-it to staging")

    assert said(notes) =~ "Hello from Pepe."
    assert llm_prompt() =~ ~s(Carry out the "ship-it" skill now.\n\nInput: to staging)
  end

  test "/skill lists them, runs one by name, and refuses one that is not there", %{project: project} do
    server = connect("editor")
    {session_id, _} = open(server, project)

    {notes, _} = prompt(server, 3, session_id, "/skill")
    assert said(notes) =~ "Available skills"
    assert said(notes) =~ "ship-it"

    {notes, _} = prompt(server, 4, session_id, "/skill ghost")
    assert said(notes) =~ "Unknown skill: ghost"
    assert llm_prompt() == nil

    {_notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(server, 5, session_id, "/skill ship_it now")
    assert llm_prompt() =~ "Input: now"
  end

  test "a slash word that is neither a command nor an offered skill is still an ordinary message", %{project: project} do
    server = connect("bare")
    {session_id, _} = open(server, project)

    {notes, %{"result" => %{"stopReason" => "end_turn"}}} = prompt(server, 3, session_id, "/ship-it now")

    assert said(notes) =~ "Hello from Pepe."
    sent = llm_prompt()
    assert sent =~ "/ship-it now"
    refute sent =~ "Carry out the"
  end

  test "a project's own skill is offered only once the operator trusts the repository", %{project: project} do
    File.mkdir_p!(Path.join(project, ".pepe/skills"))

    File.write!(
      Path.join([project, ".pepe/skills", "local-only.md"]),
      "---\nname: local-only\ndescription: Use when working in this repo.\n---\n\nSteps.\n"
    )

    server = connect("editor")
    {_id, before} = open(server, project)
    refute "local-only" in names(before)

    Project.trust(project)

    {_id, after_trust} = open(server, project, 3)
    assert "local-only" in names(after_trust)
  end

  test "parsing reads only a lone text block as a skill command, and never a path-like word" do
    assert {:command, "skill", "ship-it now"} = Commands.parse("/ship-it now", agent: "editor")
    assert :none = Commands.parse("/ship-it now", agent: "bare")
    assert :none = Commands.parse("/etc/hosts is unreadable", agent: "editor")

    blocks = [%{"type" => "text", "text" => "/ship-it"}, %{"type" => "text", "text" => "more"}]
    assert :none = Commands.from_blocks(blocks, agent: "editor")
  end
end
