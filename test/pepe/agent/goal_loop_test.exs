defmodule Pepe.Agent.GoalLoopTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.GoalLoop
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Session.Focus

  # One mock server plays both roles. The judge is recognizable by its prompt (it is the
  # only call carrying "SUCCESS CRITERION"), so we can answer it differently from the
  # worker - and make it pass only on the Nth attempt, driven by a counter.
  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()
      text = to_string(last["content"])

      content =
        if String.contains?(text, "SUCCESS CRITERION") do
          judge_reply(Agent.get_and_update(:goal_test_judge, &{&1, &1 + 1}))
        else
          "here is my work"
        end

      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    # The judge passes only once `pass_after` verdicts have been handed out.
    defp judge_reply(n) do
      if n >= Agent.get(:goal_test_pass_after, & &1) do
        ~s({"met": true, "feedback": "criterion satisfied"})
      else
        ~s({"met": false, "feedback": "the total is missing"})
      end
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_goal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Agent.start_link(fn -> 0 end, name: :goal_test_judge)
    {:ok, _} = Agent.start_link(fn -> 999 end, name: :goal_test_pass_after)

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Pepe.Config.Agent{name: "worker", model: "mock", tools: [], max_iterations: 3})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    key = "test:goal:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "worker")
    {:ok, key: key}
  end

  defp pass_after(n), do: Agent.update(:goal_test_pass_after, fn _ -> n end)

  test "stops as soon as the judge says the criterion is met", %{key: key} do
    pass_after(0)

    assert {:ok, :met, "here is my work", 1} =
             GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 3)

    goal = Focus.get_goal(key)
    assert goal["status"] == "complete"
    assert goal["criteria"] == "the answer states a total"
    assert goal["attempt"] == 1
  end

  test "retries with the judge's feedback and passes on a later attempt", %{key: key} do
    # The first verdict fails, the second passes: the loop must run exactly twice.
    pass_after(1)

    assert {:ok, :met, _answer, 2} =
             GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 3)

    assert Focus.get_goal(key)["status"] == "complete"
  end

  test "gives up at the attempt cap and reports what was missing", %{key: key} do
    # The judge never passes.
    pass_after(999)

    assert {:error, :max_attempts, _answer, "the total is missing"} =
             GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 2)

    goal = Focus.get_goal(key)
    assert goal["status"] == "blocked"
    assert goal["verdict"] == "the total is missing"
    assert goal["attempt"] == 2
  end

  test "a goal needs both an objective and a verifiable criterion", %{key: key} do
    assert GoalLoop.run(key, "", "some criterion") == {:error, :no_objective}
    assert GoalLoop.run(key, "an objective", "") == {:error, :no_criteria}
  end

  test "the attempt cap is clamped, never unbounded", %{key: key} do
    pass_after(999)

    # Asking for 500 attempts must not run 500 times - it is capped.
    assert {:error, :max_attempts, _answer, _missing} =
             GoalLoop.run(key, "sum", "a total", max_attempts: 500)

    assert Focus.get_goal(key)["max_attempts"] == 10
  end
end
