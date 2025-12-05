defmodule Cortex.Agent.SessionStopTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.Session
  alias Cortex.Agent.SessionSupervisor
  alias Cortex.Config
  alias Cortex.Config.Agent
  alias Cortex.Config.Model

  # A mock model that always asks to run `bash` (a risky tool). Combined with an
  # authorizer that never answers, the run blocks inside the permission gate — which
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
    home = Path.join(System.tmp_dir!(), "cortex_stop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

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
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:stop:#{System.unique_integer([:positive])}"}
  end

  test "stopping an idle session reports nothing is running", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")
    assert Session.stop(key) == {:error, :not_running}
  end

  test "a second message is rejected as busy, and /stop unblocks the first", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "stopper")

    # An authorizer that never answers, so the run hangs in the permission gate.
    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end

    caller = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)

    # Give the run time to reach the blocked authorize call.
    Process.sleep(200)

    # While busy, a new message is refused rather than interleaved.
    assert Session.chat(key, "again") == {:error, :busy}

    # /stop cancels the run; the original caller is unblocked with :stopped.
    assert Session.stop(key) == :ok
    assert Task.await(caller) == {:error, :stopped}

    # The session is free again.
    assert Session.stop(key) == {:error, :not_running}
  end
end
