defmodule Pepe.Runtime.StatsTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Runtime.Stats

  test "footprint reports the node's real numbers" do
    f = Stats.footprint()

    assert f.memory_mb > 0
    assert f.processes > 0
    assert f.sessions >= 0
    assert f.uptime_seconds >= 0
  end

  test "utilization is nil until there are two samples, never a fabricated zero" do
    # A single reading says nothing: the counter is cumulative.
    assert Stats.utilization(nil, Stats.sample()) == nil
    assert Stats.utilization([], []) == nil
  end

  test "utilization is the share of active time between two samples" do
    # Scheduler 1 was busy 50 of 100 wall units; scheduler 2 was idle.
    prev = [{1, 0, 0}, {2, 0, 0}]
    curr = [{1, 50, 100}, {2, 0, 100}]

    # 50 active of 200 total = 25%.
    assert Stats.utilization(prev, curr) == 25.0
  end

  test "utilization is 100 when every scheduler was busy the whole interval" do
    assert Stats.utilization([{1, 0, 0}], [{1, 100, 100}]) == 100.0
  end

  test "sample turns the counter on by itself, so CPU can't stay dark forever" do
    # Whatever the node's flag was, a sample eventually yields a real reading.
    Stats.sample()
    assert is_list(Stats.sample())
  end

  test "by_agent is a map of live sessions per agent" do
    # With no sessions for a made-up agent, it simply isn't in the map.
    refute Map.has_key?(Stats.by_agent(), "no-such-agent-#{System.unique_integer([:positive])}")
  end

  test "by_agent counts an agent's live sessions and what they hold" do
    # A name of its own, so a session another test left running can't be counted here.
    agent = "analyst-#{System.unique_integer([:positive])}"
    key = "test:stats:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, agent)
    on_exit(fn -> SessionSupervisor.terminate(key) end)

    assert %{sessions: 1, memory_kb: memory_kb} = Stats.by_agent()[agent]

    # The session process is real, so its retained memory is a real number, not a zero.
    assert memory_kb > 0
  end

  test "by_agent sums the sessions of one agent instead of listing them" do
    agent = "analyst-#{System.unique_integer([:positive])}"
    keys = for i <- 1..2, do: "test:stats:#{System.unique_integer([:positive])}:#{i}"
    for key <- keys, do: {:ok, _pid} = SessionSupervisor.ensure(key, agent)
    on_exit(fn -> Enum.each(keys, &SessionSupervisor.terminate/1) end)

    assert %{sessions: 2, memory_kb: memory_kb} = Stats.by_agent()[agent]
    assert memory_kb > 0
  end
end
