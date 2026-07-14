defmodule Pepe.Agent.SessionSupervisorRestoreTest do
  @moduledoc """
  The boot-time crash-recovery path: a session whose process died mid-turn (a restart, a kill)
  leaves a `pending` marker in its persisted file (see `Pepe.Agent.SessionPersistence`).
  `SessionSupervisor.restore/0` re-spawns every persisted session and, for the ones with a
  `pending` marker, resumes the interrupted turn and delivers the reply - so a crash mid-answer
  doesn't just leave the user hanging. `session_resume_test.exs` only ever exercises
  `Session.resume/1` on an ALREADY-RUNNING process (an in-memory `pending_resume`, set by the live
  chat call itself); this is the actual boot path, driven from a file on disk with no process
  running yet, through the real `SessionSupervisor.restore/0` entry point.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Answers plainly, so the "interrupted turn" resolves cleanly on the first call.
  defmodule ReviverPlug do
    @moduledoc false
    import Plug.Conn

    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, _body, conn} = read_body(conn)
      send(pid, :model_called)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "picking up where we left off"}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_restore_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # restore/0 (and Session's own persistence) both gate on this - off by default in the test env
    # specifically so tests never touch disk unless a test, like this one, explicitly opts in.
    prev_env = Application.get_env(:pepe, :env)
    prev_persist = Application.get_env(:pepe, :persist_sessions)
    Application.put_env(:pepe, :env, :dev)
    Application.put_env(:pepe, :persist_sessions, true)

    {:ok, server} = Bandit.start_link(plug: {ReviverPlug, self()}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "reviver", model: "mock", tools: [], max_iterations: 3})

    on_exit(fn ->
      Process.exit(server, :normal)
      Application.put_env(:pepe, :env, prev_env)

      if prev_persist == nil,
        do: Application.delete_env(:pepe, :persist_sessions),
        else: Application.put_env(:pepe, :persist_sessions, prev_persist)

      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    key = "test:restore:#{System.unique_integer([:positive])}"
    {:ok, key: key}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "a session with a pending marker on disk, and no process running yet, gets resumed on restore", %{key: key} do
    history = [Message.system("reviver"), Message.user("what's our status?")]
    SessionPersistence.save(key, "reviver", history)
    SessionPersistence.mark_pending(key, "what's our status?")

    # The exact crash scenario: a persisted file with a pending marker, no live process for it.
    assert Registry.lookup(Pepe.Agent.Registry, key) == []
    assert {:ok, "reviver", ^history, [], "what's our status?"} = SessionPersistence.load(key)

    assert SessionSupervisor.restore() == :ok

    assert_receive :model_called, 2_000

    # The interrupted turn was actually completed: the reply landed in history...
    wait_until(fn ->
      msgs = Pepe.Agent.Session.history(key)
      Enum.any?(msgs, &(&1["content"] == "picking up where we left off"))
    end)

    # ...and the pending marker is gone from disk, so a second boot wouldn't try to resume it again.
    assert {:ok, "reviver", _msgs, [], nil} = SessionPersistence.load(key)
  end

  test "a session with no pending marker is just re-spawned, nothing resumed", %{key: key} do
    history = [Message.system("reviver"), Message.user("hi"), Message.assistant("hello")]
    SessionPersistence.save(key, "reviver", history)

    assert SessionSupervisor.restore() == :ok
    refute_receive :model_called, 300

    assert [{_pid, nil}] = Registry.lookup(Pepe.Agent.Registry, key)
    assert Pepe.Agent.Session.history(key) == history
  end

  test "restore/0 is a no-op outside a persisting environment (the test-env default)" do
    Application.put_env(:pepe, :env, :test)

    key = "test:restore-noop:#{System.unique_integer([:positive])}"
    SessionPersistence.save(key, "reviver", [Message.system("x")])
    SessionPersistence.mark_pending(key, "hello?")

    assert SessionSupervisor.restore() == :ok
    refute_receive :model_called, 300
    assert Registry.lookup(Pepe.Agent.Registry, key) == []
  end
end
