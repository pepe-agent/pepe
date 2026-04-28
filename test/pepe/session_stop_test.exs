defmodule Pepe.Agent.SessionStopTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A mock model that always asks to run `bash` (a risky tool). Combined with an
  # authorizer that never answers, the run blocks inside the permission gate - which
  # is exactly the state /stop must be able to interrupt.
  defmodule BashPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      message =
        if last["role"] == "tool" do
          %{"role" => "assistant", "content" => "done"}
        else
          tool_call = %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => ~s({"command":"echo hi"})}
          }

          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]}
        end

      payload = %{
        "choices" => [
          %{
            "index" => 0,
            "message" => message,
            "finish_reason" => if(last["role"] == "tool", do: "stop", else: "tool_calls")
          }
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_stop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: BashPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model"
    })

    Config.put_agent(%Agent{name: "stopper", model: "mock", tools: ["bash"], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:stop:#{System.unique_integer([:positive])}"}
  end

  test "stopping an idle session reports nothing is running", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")
    assert Session.stop(key) == {:error, :not_running}
  end

  test "a second message queues behind the running one, and /stop cancels both", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")

    # An authorizer that never answers, so the run hangs in the permission gate.
    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end

    first = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)

    # Give the run time to reach the blocked authorize call.
    Process.sleep(200)

    # A second message no longer bounces off :busy - it queues and waits its turn.
    second = Task.async(fn -> Session.chat(key, "again", authorize: blocking) end)
    Process.sleep(100)

    # /stop cancels the in-flight run and drops the queued one; both callers get :stopped.
    assert Session.stop(key) == :ok
    assert Task.await(first) == {:error, :stopped}
    assert Task.await(second) == {:error, :stopped}

    # The session is free again.
    assert Session.stop(key) == {:error, :not_running}
  end

  test "/new recovers a wedged run and clears the queue", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")
    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end

    first = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)
    Process.sleep(200)
    second = Task.async(fn -> Session.chat(key, "again", authorize: blocking) end)
    Process.sleep(100)

    # /new cancels the stuck run and drops the queue; both callers are unblocked.
    assert Session.reset(key) == :ok
    assert Task.await(first) == {:error, :stopped}
    assert Task.await(second) == {:error, :stopped}
    assert Session.stop(key) == {:error, :not_running}
  end

  test "a queued message runs after the current turn finishes", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")
    allow = fn _name, _args, _ctx -> :once end

    first = Task.async(fn -> Session.chat(key, "one", authorize: allow) end)
    Process.sleep(50)
    second = Task.async(fn -> Session.chat(key, "two", authorize: allow) end)

    assert {:ok, _} = Task.await(first, 5000)
    assert {:ok, _} = Task.await(second, 5000)
    assert Session.stop(key) == {:error, :not_running}
  end

  test "fork seeds a new session with the history, then evolves independently", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")
    allow = fn _name, _args, _ctx -> :once end

    {:ok, _reply} = Session.chat(key, "hello", authorize: allow)
    original = Session.history(key)
    assert length(original) > 0

    new_key = key <> "-fork"
    assert {:ok, ^new_key} = Session.fork(key, new_key)

    # The branch starts as an exact copy of the source history...
    assert Session.history(new_key) == original

    # ...but is independent: a turn on the branch never touches the original.
    {:ok, _} = Session.chat(new_key, "on the branch", authorize: allow)
    assert length(Session.history(new_key)) > length(original)
    assert Session.history(key) == original

    SessionSupervisor.terminate(new_key)
  end

  test "/inline is refused when idle and accepted mid-run", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")

    # Nothing is running: /inline tells the caller to send it as a normal message.
    assert Session.inline(key, "hi") == {:error, :not_running}

    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end
    caller = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)
    Process.sleep(200)

    # A turn is in flight: /inline is accepted (folded into that turn).
    assert Session.inline(key, "also do X") == :ok

    assert Session.stop(key) == :ok
    assert Task.await(caller) == {:error, :stopped}
  end
end
