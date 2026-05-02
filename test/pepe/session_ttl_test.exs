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

  # Watch the session and wait for the news, rather than sleeping past the deadline and
  # hoping. It reports the moment the session goes, so it is both faster than a fixed
  # sleep and immune to a loaded machine that misses one.
  defp assert_evicted(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  # The opposite claim needs the same watch: that nothing happens for a while. A sleep
  # followed by `Process.alive?` reads the same but proves less, since it only samples the
  # one instant it wakes up on.
  defp refute_evicted(pid, within) do
    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, within
    Process.demonitor(ref, [:flush])
  end

  test "a session with a short idle TTL evicts itself" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent", ttl_ms: 150)
    assert Process.alive?(pid)
    assert_evicted(pid)
  end

  test "no TTL means the session lives (infinite)" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent")
    refute_evicted(pid, 300)
    SessionSupervisor.terminate(k)
  end

  test "end_session is accepted without killing the session" do
    k = key()
    {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent")
    assert :ok = Session.end_session(k)
    refute_evicted(pid, 50)
    SessionSupervisor.terminate(k)
  end

  describe "key-derived ephemeral/TTL defaults" do
    test "a widget: key defaults to ephemeral, everything else doesn't" do
      assert Session.default_ephemeral?("widget:example.com:abc")
      refute Session.default_ephemeral?("web:1")
      refute Session.default_ephemeral?("telegram:42")
      refute Session.default_ephemeral?("test:ttl:1")
    end

    test "a widget: key defaults to a non-nil TTL, everything else defaults to none" do
      assert Session.default_ttl_ms("widget:example.com:abc")
      refute Session.default_ttl_ms("web:1")
    end

    test "an explicit opt still overrides the key-derived default either way" do
      refute Session.default_ephemeral?("web:1")
      k = "web:#{System.unique_integer([:positive])}"
      {:ok, pid} = SessionSupervisor.ensure(k, "ttl-agent", ttl_ms: 150)
      assert Process.alive?(pid)
      assert_evicted(pid)
    end
  end
end
