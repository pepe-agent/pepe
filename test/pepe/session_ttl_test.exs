defmodule Pepe.SessionTtlTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_ttl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Config.put_agent(%Config.Agent{name: "ttl-agent", system_prompt: "hi"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp key, do: "test:ttl:#{System.unique_integer([:positive])}"

  test "a session with a short idle TTL evicts itself" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent", ttl_ms: 150)
    assert Process.alive?(pid)
    Process.sleep(400)
    refute Process.alive?(pid)
  end

  test "no TTL means the session lives (infinite)" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent")
    Process.sleep(300)
    assert Process.alive?(pid)
    SessionSupervisor.terminate(k)
  end

  test "end_session is accepted without killing the session" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent")
    assert :ok = Session.end_session(k)
    Process.sleep(50)
    assert Process.alive?(pid)
    SessionSupervisor.terminate(k)
  end
end
