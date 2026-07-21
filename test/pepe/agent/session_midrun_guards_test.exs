defmodule Pepe.Agent.SessionMidRunGuardsTest do
  @moduledoc """
  While a turn is in flight, the mutating session commands must not run: `run_done` will overwrite
  agent_name/messages with the finishing run's values, so a mid-run undo/compact/agent-switch would
  be silently reverted (and a switch's history wipe would corrupt the queued turn, which would then
  execute on the OLD agent). undo/compact/aside report `:busy`; a re-assert of the running agent
  stays a no-op and never switches.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Asks for the risky `bash` tool, then answers "done" once the tool result comes back.
  defmodule BashPlug do
    @moduledoc false
    import Plug.Conn

    def init(o), do: o

    def call(conn, _) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      message =
        if last["role"] == "tool" do
          %{"role" => "assistant", "content" => "done"}
        else
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c1", "type" => "function", "function" => %{"name" => "bash", "arguments" => ~s({"command":"rm -rf /tmp/x"})}}
            ]
          }
        end

      payload = %{
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => if(last["role"] == "tool", do: "stop", else: "tool_calls")}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: BashPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "runner", model: "mock", tools: ["bash"], max_iterations: 5})
    Config.put_agent(%Agent{name: "other", model: "mock", tools: ["bash"], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:guard:#{System.unique_integer([:positive])}"}
  end

  # Parks the run inside the permission gate and announces the runner pid, so the test knows the
  # turn is really in flight (not guessed at with a sleep) and can release it later.
  defp gate(test_pid) do
    fn _name, _args, _ctx ->
      send(test_pid, {:at_gate, self()})
      receive do: (:release -> :once)
    end
  end

  test "undo, compact and aside report :busy mid-run; a running agent re-assert never switches", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "runner")

    blocking = gate(self())
    run = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)
    assert_receive {:at_gate, runner}, 5_000

    # The turn is in flight. Every mutating command is refused or no-ops.
    assert Session.undo(key) == {:error, :busy}
    assert Session.compact(key) == {:error, :busy}
    assert Session.aside(key, "quick question", []) == {:error, :busy}

    # Re-asserting an agent mid-run (what a per-topic binding does every turn) stays a no-op: a
    # genuine switch would be clobbered by run_done and would corrupt the turn.
    assert Session.set_agent(key, "other") == :ok
    assert Session.status(key).agent in ["runner", "default/runner"]

    # Let the run finish; the agent it ran on is untouched by the mid-run set_agent.
    send(runner, :release)
    assert {:ok, "done"} = Task.await(run, 5_000)
    assert Session.status(key).agent in ["runner", "default/runner"]

    # Idle again: undo works now (the guard was about the running turn, not a permanent block).
    assert Session.undo(key) == :ok
  end
end
