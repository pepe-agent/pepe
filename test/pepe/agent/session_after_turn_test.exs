defmodule Pepe.Agent.SessionAfterTurnTest do
  @moduledoc """
  What a session is told to do once the current turn ends (switch agent, clear its context)
  belongs to THAT turn. When the turn is stopped, reset or killed before it ends, the pending
  action has to go with it: a `/stop` after `switch_agent`, a `/new` after `end_session`, or a
  crashed run task must not leave the action armed for the next, unrelated turn.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_afterturn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs FIRST, see Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    Process.register(self(), :pepe_afterturn_test)

    {:ok, server} =
      Bandit.start_link(
        plug: fn conn, _ ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          send(:pepe_afterturn_test, :hit)
          Process.sleep(250)
          payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]}
          conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(payload))
        end,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    Config.put_model(%Model{name: "slow", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "eng", model: "slow", system_prompt: "eng", tools: [], max_iterations: 5})
    Config.put_agent(%Agent{name: "sup", model: "slow", system_prompt: "sup", tools: [], max_iterations: 5})

    key = "test:afterturn:#{System.unique_integer([:positive])}"
    {:ok, _} = SessionSupervisor.ensure(key, "eng")
    {:ok, key: key}
  end

  defp start_turn(key) do
    task = Task.async(fn -> Session.chat(key, "first") end)
    assert_receive :hit, 2_000
    task
  end

  test "a /stop after switch_agent cancels the switch, the next turn stays with the same agent", %{key: key} do
    task = start_turn(key)
    Session.switch_agent(key, "sup")
    Process.sleep(20)
    :ok = Session.stop(key)
    assert {:error, :stopped} = Task.await(task, 2_000)

    assert {:ok, "ok"} = Session.chat(key, "second")
    assert Session.status(key).agent =~ "eng"
  end

  test "a /new after end_session does not wipe the history of the turn that comes next", %{key: key} do
    task = start_turn(key)
    Session.end_session(key)
    Process.sleep(20)
    :ok = Session.reset(key)
    assert {:error, :stopped} = Task.await(task, 2_000)

    assert {:ok, "ok"} = Session.chat(key, "second")
    assert Enum.any?(Session.history(key), &(&1["role"] == "user" and &1["content"] == "second"))
  end

  test "a run task that dies leaves no switch armed for the next turn", %{key: key} do
    task = start_turn(key)
    Session.switch_agent(key, "sup")
    Process.sleep(20)

    %{running: %{task: pid}} = :sys.get_state({:via, Registry, {Pepe.Agent.Registry, key}})
    Process.exit(pid, :kill)
    assert {:error, :stopped} = Task.await(task, 2_000)

    assert {:ok, "ok"} = Session.chat(key, "second")
    assert Session.status(key).agent =~ "eng"
  end
end
