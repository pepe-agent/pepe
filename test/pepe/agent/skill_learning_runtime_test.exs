defmodule Pepe.Agent.SkillLearningRuntimeTest do
  @moduledoc """
  The other half of `Pepe.Agent.SkillLearningTest`: the note has to actually reach the
  model call the turn ends on, and it has to stay out of the history that gets persisted -
  a `<system-reminder>` saved into a session would be replayed forever as if the user had
  typed it.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Runtime
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      msgs = raw |> Jason.decode!() |> Map.fetch!("messages")
      send(Process.whereis(:skill_learning_test_pid), {:sent, msgs})

      message =
        if Enum.any?(msgs, &(&1["role"] == "tool")) do
          %{"role" => "assistant", "content" => "done"}
        else
          %{"role" => "assistant", "content" => nil, "tool_calls" => Elixir.Agent.get(:sl_calls, & &1)}
        end

      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Process.register(self(), :skill_learning_test_pid)
    {:ok, _} = Elixir.Agent.start_link(fn -> [] end, name: :sl_calls)
    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://127.0.0.1:#{port}", api_key: "k", model: "m"})

    agent = %Agent{
      name: "worker",
      model: "mock",
      system_prompt: "hi",
      tools: ["read_file", "write_file", "list_dir"],
      auto_approve: ["*"],
      max_iterations: 3,
      skill_learning: true
    }

    Config.put_agent(agent)

    ws = Pepe.Agent.Workspace.dir(agent.name)
    File.mkdir_p!(ws)
    for n <- 1..2, do: File.write!(Path.join(ws, "f#{n}.txt"), "content-#{n}")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{agent: agent, home: home}
  end

  defp call(id, name, args),
    do: %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}

  defp ask_for_four_calls do
    Elixir.Agent.update(:sl_calls, fn _ ->
      [
        call("a", "read_file", %{"path" => "f1.txt"}),
        call("b", "read_file", %{"path" => "f2.txt"}),
        call("c", "list_dir", %{"path" => "."}),
        call("d", "list_dir", %{"path" => "."})
      ]
    end)
  end

  defp reminders(msgs) do
    for m <- msgs, m["role"] == "user", is_binary(m["content"]), m["content"] =~ "save it as a skill", do: m["content"]
  end

  test "the note rides along on the call that follows the work, and is never persisted", %{agent: agent, home: home} do
    ask_for_four_calls()

    {:ok, _reply, messages} = Runtime.converse(agent, "go", cwd: home)

    assert_receive {:sent, first}
    assert reminders(first) == [], "nothing has happened yet on the opening call"

    assert_receive {:sent, second}
    assert [_note] = reminders(second)

    assert reminders(messages) == [], "the returned history is what gets persisted"
  end

  test "an agent with the flag off never sees it", %{agent: agent, home: home} do
    Config.put_agent(%{agent | skill_learning: false})
    ask_for_four_calls()

    {:ok, _reply, _messages} = Runtime.converse(%{agent | skill_learning: false}, "go", cwd: home)

    assert_receive {:sent, _first}
    assert_receive {:sent, second}
    assert reminders(second) == []
  end
end
