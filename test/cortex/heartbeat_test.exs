defmodule Cortex.HeartbeatTest do
  use ExUnit.Case, async: false

  alias Cortex.Heartbeat
  alias Cortex.Heartbeat.Cooldown
  alias Cortex.Heartbeat.Events

  describe "Events" do
    test "push/take round-trips oldest-first and clears the queue" do
      key = "test:#{System.unique_integer([:positive])}"
      Events.push(key, "first")
      Events.push(key, "second")

      assert Events.take(key) == ["first", "second"]
      assert Events.take(key) == []
    end

    test "count reflects pending events without clearing" do
      key = "test:#{System.unique_integer([:positive])}"
      Events.push(key, "a")
      Events.push(key, "b")
      assert Events.count(key) == 2
      assert Events.count(key) == 2
    end
  end

  describe "Cooldown" do
    test "allows the first pulse, defers an immediate second one (min spacing)" do
      key = "cd:#{System.unique_integer([:positive])}"
      assert Cooldown.allow?(key) == :ok
      assert Cooldown.allow?(key) == {:defer, :min_spacing}
    end

    test "flood breaker trips once 5 fires land inside the 60s window" do
      key = "cd:#{System.unique_integer([:positive])}"
      now = System.monotonic_time(:millisecond)
      # Most recent fire 31s ago (clears the 30s min-spacing floor on its own), with
      # 4 more before it — all 5 still inside the 60s flood window.
      for i <- 0..4, do: :ets.insert(Cooldown, {key, now - 31_000 - i * 6_000})
      assert Cooldown.allow?(key) == {:defer, :flood}
    end
  end

  describe "silent?/1" do
    test "recognizes the sentinel, tolerant of case/whitespace/trailing period" do
      assert Heartbeat.silent?("HEARTBEAT_OK")
      assert Heartbeat.silent?("  heartbeat_ok.\n")
      refute Heartbeat.silent?("Your build finished successfully!")
      refute Heartbeat.silent?("")
    end

    test "tolerates stray wrapping punctuation models add" do
      assert Heartbeat.silent?("*HEARTBEAT_OK*")
      assert Heartbeat.silent?("\"HEARTBEAT_OK\"")
      assert Heartbeat.silent?("HEARTBEAT_OK!!!")
      assert Heartbeat.silent?(".HEARTBEAT_OK.")
      assert Heartbeat.silent?("  _HEARTBEAT_OK_  ")
    end

    test "the sentinel embedded in real prose is not silence" do
      refute Heartbeat.silent?("HEARTBEAT_OK — but also, your deploy is done.")
      refute Heartbeat.silent?("Status: HEARTBEAT_OK")
    end
  end

  describe "build_prompt/2" do
    test "includes pending events and clears them" do
      key = "bp:#{System.unique_integer([:positive])}"
      Events.push(key, "background job finished")

      prompt = Heartbeat.build_prompt(key, "nonexistent-agent")
      assert prompt =~ "background job finished"
      assert prompt =~ "HEARTBEAT_OK"
      # Consumed — a second build sees no events.
      assert Heartbeat.build_prompt(key, "nonexistent-agent") =~ "nothing worth"
    end

    test "includes HEARTBEAT.md content when present" do
      home = Path.join(System.tmp_dir!(), "cortex_hb_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      prev = System.get_env("CORTEX_HOME")
      System.put_env("CORTEX_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
        File.rm_rf(home)
      end)

      dir = Cortex.Agent.Workspace.dir("watcher")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "HEARTBEAT.md"), "Watch for deploy failures.")

      assert Heartbeat.build_prompt("k", "watcher") =~ "Watch for deploy failures."
    end
  end

  describe "active_hours?/2" do
    test "no window configured is always active" do
      assert Heartbeat.active_hours?(nil, 3)
    end

    test "inside/outside a normal window" do
      assert Heartbeat.active_hours?([8, 22], 8)
      assert Heartbeat.active_hours?([8, 22], 21)
      refute Heartbeat.active_hours?([8, 22], 22)
      refute Heartbeat.active_hours?([8, 22], 3)
    end

    test "a nonsensical window fails open (always active)" do
      assert Heartbeat.active_hours?([22, 8], 3)
    end
  end
end
