defmodule Pepe.Agent.SessionGoalReminderTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Session.Focus

  # Captures every request body it sees (so the test can inspect exactly what was
  # sent to the model) and always replies with a plain, no-tool-call assistant turn.
  defmodule CapturePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      Agent.update(:goal_reminder_capture, &[Jason.decode!(body) | &1])

      payload = %{"choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "ok"}, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_goalrem_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, _} = Agent.start_link(fn -> [] end, name: :goal_reminder_capture)
    {:ok, server} = Bandit.start_link(plug: CapturePlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Pepe.Config.Agent{name: "goalie", model: "mock", tools: [], max_iterations: 5})

    key = "test:goalrem:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Focus.clear_goal(key)
      Focus.clear_plan(key)
    end)

    {:ok, key: key}
  end

  defp captured_requests, do: Agent.get(:goal_reminder_capture, &Enum.reverse/1)

  test "a set goal is injected as a reminder each turn but never persisted", %{key: key} do
    Focus.put_goal(key, %{"objective" => "ship the release", "status" => "active", "at" => 0})

    {:ok, _pid} = SessionSupervisor.ensure(key, "goalie")
    {:ok, _reply} = Session.chat(key, "how's it going", authorize: nil)

    [req1] = captured_requests()
    msgs1 = req1["messages"]

    reminder = Enum.find(msgs1, &(&1["content"] && String.contains?(&1["content"], "<system-reminder>")))
    assert reminder
    assert reminder["content"] =~ "Goal: ship the release (active)"
    # It sits right before the real user turn, not folded into it.
    assert Enum.at(msgs1, -1)["content"] == "how's it going"
    assert Enum.at(msgs1, -2) == reminder

    # Not persisted: the session's own history has no <system-reminder> anywhere.
    refute Enum.any?(Session.history(key), &(&1["content"] && String.contains?(&1["content"], "<system-reminder>")))

    # A second turn still gets a fresh reminder, and history still has none.
    {:ok, _reply2} = Session.chat(key, "any update", authorize: nil)
    [_req1, req2] = captured_requests()
    assert Enum.any?(req2["messages"], &(&1["content"] && String.contains?(&1["content"], "<system-reminder>")))
    refute Enum.any?(Session.history(key), &(&1["content"] && String.contains?(&1["content"], "<system-reminder>")))
  end

  test "no goal or plan set means no reminder is sent", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "goalie")
    {:ok, _reply} = Session.chat(key, "hi", authorize: nil)

    [req] = captured_requests()
    refute Enum.any?(req["messages"], &(&1["content"] && String.contains?(&1["content"], "<system-reminder>")))
  end
end
