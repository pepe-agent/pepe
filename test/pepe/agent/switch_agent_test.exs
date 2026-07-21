defmodule Pepe.Agent.SwitchAgentTest do
  @moduledoc """
  `Session.switch_agent/2` is the primitive behind the `switch_agent` tool: hand this
  conversation to a different agent from now on, triggered by plain language rather
  than the `/agent NAME` command. Mirrors `set_agent_keeps_history_test.exs`'s pattern
  for the immediate case; the deferred-while-running case needs a genuine in-flight
  turn (a slow mock, like `session_midrun_fold_test.exs` uses) since that's the whole
  point of the deferral - rebinding the session out from under a run that's still
  reading its own snapshot of the history would corrupt what it reports back.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_switchagent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "eng", system_prompt: "eng", tools: [], max_iterations: 5})
    Config.put_agent(%Agent{name: "sup", system_prompt: "sup", tools: [], max_iterations: 5})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:switchagent:#{System.unique_integer([:positive])}"}
  end

  test "with no turn running, the switch is immediate and starts fresh", %{key: key} do
    {:ok, _} = SessionSupervisor.ensure(key, "eng")

    :ok =
      Session.seed(key, %{
        messages: [Message.system("eng"), Message.user("oi"), Message.assistant("olá")],
        model_override: nil,
        pii_map: []
      })

    Session.switch_agent(key, "sup")
    # switch_agent/2 is a cast - give it a moment to land.
    Process.sleep(20)

    assert Session.status(key).agent == "sup"
    assert [%{"role" => "system"}] = Session.history(key)
  end

  describe "while a turn is running" do
    defp slow_mock!(role) do
      {:ok, server} =
        Bandit.start_link(
          plug: fn conn, _ ->
            {:ok, _body, conn} = Plug.Conn.read_body(conn)
            send(:pepe_switchagent_test, {:hit, role})
            Process.sleep(300)

            payload = %{
              "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "final answer"}, "finish_reason" => "stop"}]
            }

            conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(payload))
          end,
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      port
    end

    setup do
      Process.register(self(), :pepe_switchagent_test)
      port = slow_mock!(:eng)
      Config.put_model(%Model{name: "slow", base_url: "http://127.0.0.1:#{port}", api_key: "x", model: "m"})
      Config.put_agent(%Agent{name: "eng", model: "slow", system_prompt: "eng", tools: [], max_iterations: 5})
      :ok
    end

    test "the switch is deferred until the turn finishes, then applies", %{key: key} do
      {:ok, _} = SessionSupervisor.ensure(key, "eng")

      run = Task.async(fn -> Session.chat(key, "oi") end)
      assert_receive {:hit, :eng}, 2_000

      Session.switch_agent(key, "sup")
      Process.sleep(20)
      # Still the original agent - the switch hasn't applied yet, the turn is still using it.
      assert Session.status(key).agent == "eng"

      assert {:ok, "final answer"} = Task.await(run, 5_000)

      assert Session.status(key).agent == "sup"
      assert [%{"role" => "system"}] = Session.history(key)
    end

    test "if the target agent is gone by the time the turn ends, the session stays put instead of binding to a ghost", %{key: key} do
      {:ok, _} = SessionSupervisor.ensure(key, "eng")

      run = Task.async(fn -> Session.chat(key, "oi") end)
      assert_receive {:hit, :eng}, 2_000

      Session.switch_agent(key, "sup")
      Config.delete_agent("sup")

      assert {:ok, "final answer"} = Task.await(run, 5_000)

      # The canonical handle the run itself resolved to ("default/eng"), not the raw
      # "eng" string the session was started with - same distinction
      # set_agent_keeps_history_test.exs's second test relies on.
      assert Session.status(key).agent == Config.get_agent("eng").name
    end
  end
end
