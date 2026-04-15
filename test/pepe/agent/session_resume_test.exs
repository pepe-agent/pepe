defmodule Pepe.Agent.SessionResumeTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # A mock model that always asks to run `bash` (a risky tool), so combined with an
  # authorizer that never answers, the run blocks inside the permission gate - a
  # reliable "still running" window (mirrors session_stop_test.exs).
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
    home = Path.join(System.tmp_dir!(), "pepe_resume_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: BashPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})
    Config.put_agent(%Agent{name: "reviver", model: "mock", tools: ["bash"], max_iterations: 5})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    key = "test:resume:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "reviver")
    %{key: key}
  end

  test "an ordinary session (nothing interrupted) has nothing to resume", %{key: key} do
    assert Session.resume(key) == :nothing_pending
  end

  test "resume is refused while a turn is already running", %{key: key} do
    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end
    caller = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)
    Process.sleep(200)

    assert Session.resume(key) == {:error, :busy}

    assert Session.stop(key) == :ok
    assert Task.await(caller) == {:error, :stopped}
  end

  test "stopping a turn clears its pending marker - nothing left to resume", %{key: key} do
    blocking = fn _name, _args, _ctx -> receive do: (:never -> :once) end
    caller = Task.async(fn -> Session.chat(key, "go", authorize: blocking) end)
    Process.sleep(200)

    assert Session.stop(key) == :ok
    assert Task.await(caller) == {:error, :stopped}

    assert Session.resume(key) == :nothing_pending
  end

  test "a normal completed turn leaves nothing pending afterwards", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "hello")
    assert Session.resume(key) == :nothing_pending
  end
end
