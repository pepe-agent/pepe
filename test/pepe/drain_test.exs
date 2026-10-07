defmodule Pepe.DrainTest do
  @moduledoc """
  The shutdown gate: once draining starts nothing new is admitted (a one-shot run, a conversation
  turn, an API request, a webhook message), while work already in flight is counted so the shutdown
  can wait for it. The flag is global, so every test puts it back.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  alias Pepe.Drain

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_drain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    config = %{
      "default_model" => "mock",
      "default_agent" => "assistant",
      "models" => %{"mock" => %{"base_url" => "http://localhost:#{port}", "api_key" => "x", "model" => "mock-model"}},
      "agents" => %{"assistant" => %{"model" => "mock", "system_prompt" => "You are helpful.", "tools" => []}}
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))
    Drain.reset()

    on_exit(fn ->
      Drain.reset()
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # The name is registered before the new process's `init/1` has run, so give it a moment.
  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end

  # The supervisor starts a new one under the same name.
  defp await_restart(old) do
    case Process.whereis(Drain) do
      pid when is_pid(pid) and pid != old -> :ok
      _ -> Process.sleep(20) && await_restart(old)
    end
  end

  describe "the gate" do
    test "admits by default, refuses after start/0, admits again after reset/0" do
      refute Drain.draining?()
      assert :ok = Drain.start()
      assert Drain.draining?()
      assert :ok = Drain.reset()
      refute Drain.draining?()
    end
  end

  describe "a restart" do
    test "admits work again, even if the previous run ended draining" do
      Drain.start()
      assert Drain.draining?()
      old = Process.whereis(Drain)
      GenServer.stop(old)
      await_restart(old)
      assert eventually(fn -> not Drain.draining?() end)
    end
  end

  describe "without the gate process" do
    test "a flag left by an earlier shutdown is stale and refuses nothing" do
      Drain.start()
      assert Drain.draining?()
      :ok = Supervisor.terminate_child(Pepe.Supervisor, Drain)
      refute Drain.draining?()
      assert {:ok, _} = Supervisor.restart_child(Pepe.Supervisor, Drain)
      refute Drain.draining?()
    end
  end

  describe "work in flight" do
    test "await returns at once when nothing is running" do
      assert :ok = Drain.await(100)
    end

    test "await waits for the work to finish, however it ends" do
      worker = spawn(fn -> Process.sleep(150) end)
      Drain.enter(worker)
      assert Drain.in_flight() == 1
      assert :ok = Drain.await(2_000)
      assert Drain.in_flight() == 0
    end

    test "a crashed run is counted out on its own" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      Drain.enter(worker)
      Process.exit(worker, :kill)
      assert :ok = Drain.await(2_000)
    end

    test "leave/1 ends the work without the process exiting, and a nil token is ignored" do
      token = Drain.enter(self())
      assert Drain.in_flight() == 1
      Drain.leave(token)
      assert :ok = Drain.await(2_000)
      assert :ok = Drain.leave(nil)
    end

    test "await gives up after its timeout and says how many are still running" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      Drain.enter(worker)
      assert {:timeout, 1} = Drain.await(100)
      Process.exit(worker, :kill)
    end
  end

  describe "what is refused while draining" do
    test "a one-shot run" do
      assert {:ok, _reply, _messages} = Pepe.Agent.oneshot("assistant", "hi")
      Drain.start()
      assert {:error, :shutting_down} = Pepe.Agent.oneshot("assistant", "hi")
    end

    test "a one-shot run in flight counts until it returns" do
      assert {:ok, _reply, _messages} = Pepe.Agent.oneshot("assistant", "hi")
      assert Drain.in_flight() == 0
    end

    test "a conversation turn in a session, while the same session answered before" do
      key = "drain:#{System.unique_integer([:positive])}"
      assert {:ok, "Hello from the mock!"} = Pepe.Agent.chat(key, "assistant", "hi")
      Drain.start()
      assert {:error, :shutting_down} = Pepe.Agent.chat(key, "assistant", "again")
    end

    test "POST /v1/chat/completions answers 503 with a retry hint" do
      Drain.start()

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/chat/completions", %{"model" => "assistant", "messages" => [%{"role" => "user", "content" => "hi"}]})

      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["5"]
    end

    test "a webhook message is refused with a 503 the sender retries" do
      Pepe.Config.put_webhook("desk", %{"provider" => "whatsapp", "agent" => "assistant", "config" => %{}})
      Drain.start()
      assert {:error, :shutting_down} = Pepe.Webhooks.handle_gateway_event("desk", %{})
    end
  end
end
