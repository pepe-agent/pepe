defmodule Pepe.Agent.GoalLoopTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.GoalLoop
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Session.Focus

  # One mock server plays both roles. The judge is recognizable by its prompt (it is the
  # only call carrying "SUCCESS CRITERION"), so we can answer it differently from the
  # worker - and make it pass only on the Nth attempt, driven by a counter. `mode` picks
  # how each role misbehaves, so a test can break the judge without breaking the worker.
  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()
      text = to_string(last["content"])

      if String.contains?(text, "SUCCESS CRITERION"), do: judge(conn), else: worker(conn)
    end

    defp worker(conn) do
      case mode() do
        :worker_fails -> fail(conn)
        _ -> reply(conn, "here is my work")
      end
    end

    defp judge(conn) do
      n = Agent.get_and_update(:goal_test_judge, &{&1, &1 + 1})

      case mode() do
        # No JSON at all in the reply.
        :judge_unreadable -> reply(conn, "Honestly, it looks fine to me.")
        # JSON, but `met` is not the boolean the contract requires.
        :judge_not_boolean -> reply(conn, ~s({"met": "yes", "feedback": "all good"}))
        # The judge call itself fails (a 4xx, which the client does not retry - a 5xx
        # would only make the same point several seconds slower).
        :judge_fails -> fail(conn)
        _ -> reply(conn, verdict(n))
      end
    end

    # The judge passes only once `pass_after` verdicts have been handed out.
    defp verdict(n) do
      if n >= Agent.get(:goal_test_pass_after, & &1) do
        ~s({"met": true, "feedback": "criterion satisfied"})
      else
        ~s({"met": false, "feedback": "the total is missing"})
      end
    end

    defp mode, do: Agent.get(:goal_test_mode, & &1)

    defp reply(conn, content) do
      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    defp fail(conn) do
      conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error": "no"}))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_goal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Agent.start_link(fn -> 0 end, name: :goal_test_judge)
    {:ok, _} = Agent.start_link(fn -> 999 end, name: :goal_test_pass_after)
    {:ok, _} = Agent.start_link(fn -> :ok end, name: :goal_test_mode)

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

  defp mode(m), do: Agent.update(:goal_test_mode, fn _ -> m end)

  defp judge_calls, do: Agent.get(:goal_test_judge, & &1)

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

  describe "a judge that cannot be understood" do
    test "prose with no JSON never approves: the loop keeps trying and gives up", %{key: key} do
      mode(:judge_unreadable)

      assert {:error, :max_attempts, "here is my work", missing} =
               GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 2)

      # Fail-closed: an unreadable verdict is a failed one, so the loop retried and then
      # gave up, rather than letting an ungraded result through as if it had passed.
      assert missing =~ "unreadable"
      assert judge_calls() == 2

      goal = Focus.get_goal(key)
      assert goal["status"] == "blocked"
      assert goal["attempt"] == 2
    end

    test "JSON without a boolean `met` never approves either", %{key: key} do
      mode(:judge_not_boolean)

      assert {:error, :max_attempts, _answer, missing} =
               GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 1)

      # `{"met": "yes"}` parses as JSON but breaks the contract - it must not pass.
      assert missing =~ "unreadable"
      assert Focus.get_goal(key)["status"] == "blocked"
    end

    test "a judge that cannot be reached never approves either", %{key: key} do
      mode(:judge_fails)

      assert {:error, :max_attempts, _answer, missing} =
               GoalLoop.run(key, "sum the numbers", "the answer states a total", max_attempts: 1)

      assert missing =~ "could not be reached"
      assert Focus.get_goal(key)["status"] == "blocked"
    end
  end

  test "a failed run blocks the goal and surfaces the reason", %{key: key} do
    mode(:worker_fails)

    assert {:error, {:http_error, 400, _body}} =
             GoalLoop.run(key, "sum the numbers", "the answer states a total")

    # The work never produced anything, so nothing was judged...
    assert judge_calls() == 0

    # ...and the goal says so instead of sitting "active" forever.
    goal = Focus.get_goal(key)
    assert goal["status"] == "blocked"
    assert goal["verdict"] =~ "run failed"
  end
end
