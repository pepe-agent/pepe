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
    Pepe.RepoSetup.start!()

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

    # Registered last so it runs FIRST: a run still in flight has to be stopped while the config
    # and PEPE_HOME it is running against still exist, or it carries on into the next test and
    # calls that test's mock. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    {:ok, key: key}
  end

  defp captured_requests, do: Agent.get(:goal_reminder_capture, &Enum.reverse/1)

  defp with_content(msgs, fragment),
    do: Enum.filter(msgs, &(&1["content"] && String.contains?(&1["content"], fragment)))

  # The conversation history minus the system prompt - the behavior contract itself
  # mentions `<system-reminder>` by name (teaching the agent how to read the notes),
  # so "no reminder was persisted" must be asserted against the turns, not the prompt.
  defp turns(key), do: Enum.reject(Session.history(key), &(&1["role"] == "system"))

  test "a set goal is injected as a reminder each turn but never persisted", %{key: key} do
    Focus.put_goal(key, %{"objective" => "ship the release", "status" => "active", "at" => 0})

    {:ok, _pid} = SessionSupervisor.ensure(key, "goalie")
    {:ok, _reply} = Session.chat(key, "how's it going", authorize: nil)

    [req1] = captured_requests()
    msgs1 = req1["messages"]

    [reminder] = with_content(msgs1, "Goal: ship the release (active)")
    assert reminder["content"] =~ "<system-reminder>"
    # It sits right before the real user turn, not folded into it.
    assert Enum.at(msgs1, -1)["content"] == "how's it going"
    assert Enum.at(msgs1, -2) == reminder

    # Not persisted: the session's own history has no <system-reminder> anywhere.
    assert with_content(turns(key), "<system-reminder>") == []

    # A second turn still gets a fresh reminder, and history still has none.
    {:ok, _reply2} = Session.chat(key, "any update", authorize: nil)
    [_req1, req2] = captured_requests()
    assert [_] = with_content(req2["messages"], "Goal: ship the release (active)")
    assert with_content(turns(key), "<system-reminder>") == []
  end

  test "no goal or plan set means no goal reminder is sent", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "goalie")
    {:ok, _reply} = Session.chat(key, "hi", authorize: nil)

    [req] = captured_requests()
    assert with_content(req["messages"], "Goal:") == []
  end

  test "the current time is injected fresh each turn, never in the frozen system prompt or history", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "goalie")
    {:ok, _reply} = Session.chat(key, "what time is it", authorize: nil)
    {:ok, _reply2} = Session.chat(key, "and now", authorize: nil)

    [req1, req2] = captured_requests()

    for req <- [req1, req2] do
      [note] = with_content(req["messages"], "Current time:")
      assert note["role"] == "user"
      assert note["content"] =~ "<system-reminder>"
      # Not baked into the (session-stable, cache-friendly) system prompt.
      [system | _] = req["messages"]
      assert system["role"] == "system"
      refute system["content"] =~ "Current time"
    end

    # Ephemeral: the stored history never carries it, so it can't go stale there.
    assert with_content(turns(key), "Current time:") == []
  end
end
