defmodule Pepe.Agent.RunObserversTest do
  @moduledoc """
  `Pepe.Agent.RunObservers` dispatches Runtime lifecycle events to installed
  `Pepe.Agent.RunObserver` plugins, off the run-owning process, without ever blocking or
  crashing the turn - and disables a repeatedly-failing observer across runs, not just
  within one.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.RunObservers

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_run_observers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_run_observers)
    end)

    {:ok, home: home}
  end

  test "with no observer installed, attach/1 is a total no-op" do
    assert RunObservers.attach("some-agent") == :started
    assert Process.get(:pepe_run_observers) == nil
    # notify/1 and finish/1 must not raise even with nothing attached.
    assert RunObservers.notify({:tool_call, "bash"}) == :ok
    assert RunObservers.finish(:ok) == :ok
  end

  test "an installed observer sees events in order, ending with run_end", %{home: home} do
    write_recorder(home, "recorder", ~w(run_start tool_call tool_result done run_end)a)

    RunObservers.attach("agent-x")
    RunObservers.notify({:tool_call, "bash", "ls"})
    RunObservers.notify({:tool_result, "bash", "ok"})
    RunObservers.notify({:done, "all done"})
    RunObservers.finish(:ok)

    assert_receive {:observed, :run_start, {:run_start, "agent-x"}}, 1_000
    assert_receive {:observed, :tool_call, {:tool_call, "bash"}}, 1_000
    assert_receive {:observed, :tool_result, {:tool_result, "bash", "ok"}}, 1_000
    assert_receive {:observed, :done, {:done, "all done"}}, 1_000
    assert_receive {:observed, :run_end, {:run_end, :ok}}, 1_000
  end

  test "tool_call args are stripped before an observer sees them", %{home: home} do
    write_recorder(home, "recorder", [:tool_call])

    RunObservers.attach("agent-x")
    RunObservers.notify({:tool_call, "bash", "rm -rf / --token=SECRET"})
    RunObservers.finish(:ok)

    assert_receive {:observed, :tool_call, payload}, 1_000
    assert payload == {:tool_call, "bash"}
  end

  test "an observer only receives events it subscribed to", %{home: home} do
    write_recorder(home, "recorder", [:done])

    RunObservers.attach("agent-x")
    RunObservers.notify({:tool_call, "bash", "ls"})
    RunObservers.notify({:done, "all done"})
    RunObservers.finish(:ok)

    refute_receive {:observed, :tool_call, _}, 200
    assert_receive {:observed, :done, _}, 1_000
  end

  test "a crashing observer degrades that observation, never the caller", %{home: home} do
    File.write!(Path.join([home, "plugins", "crasher.exs"]), """
    defmodule PepeRunObserversTest.Crasher do
      @behaviour Pepe.Agent.RunObserver
      def name, do: "crasher"
      def subscriptions, do: [:done]
      def handle_event(_event, _payload, _meta), do: raise("boom")
    end
    """)

    RunObservers.attach("agent-x")
    # notify/1 itself never raises, regardless of what the observer does with the event.
    assert RunObservers.notify({:done, "all done"}) == :ok
    assert RunObservers.finish(:ok) == :ok
  end

  test "an observer disabled after 3 consecutive failures stays disabled across runs", %{home: home} do
    mod = PepeRunObserversTest.AlwaysFails

    File.write!(Path.join([home, "plugins", "always_fails.exs"]), """
    defmodule #{inspect(mod)} do
      @behaviour Pepe.Agent.RunObserver
      def name, do: "always_fails"
      def subscriptions, do: [:done]
      def handle_event(_event, _payload, _meta), do: raise("boom")
    end
    """)

    on_exit(fn -> Pepe.Agent.RunObservers.Health.reset(mod) end)

    for _ <- 1..3 do
      RunObservers.attach("agent-x")
      RunObservers.notify({:done, "all done"})
      RunObservers.finish(:ok)
      # Let the runner process the event before the next run re-probes installed/0.
      Process.sleep(20)
    end

    assert Pepe.Agent.RunObservers.Health.disabled?(mod)

    # Health.disabled?/1 is checked at attach/1 time (installed/0), so a 4th run's roster
    # doesn't even include it any more - nothing left to fail.
    RunObservers.attach("agent-x")
    assert Process.get(:pepe_run_observers) == nil
  end

  test "a nested attach/1 (e.g. send_to_agent's inner run, same process) reports :nested and leaves the outer attachment alone",
       %{home: home} do
    write_recorder(home, "recorder", ~w(run_start done run_end)a)

    # Outermost run owns the attachment - mirrors Pepe.Trace.start/4's :started/:nested split.
    assert RunObservers.attach("outer-agent") == :started
    runner_before = Process.get(:pepe_run_observers)

    # A sub-agent run sharing the same process (send_to_agent) must see itself as nested,
    # not silently take over - Runtime.run/3 uses this to skip calling finish/1 itself,
    # which would otherwise tear down the outer run's runner mid-flight.
    assert RunObservers.attach("inner-agent") == :nested
    assert Process.get(:pepe_run_observers) == runner_before

    RunObservers.notify({:done, "still here"})
    assert_receive {:observed, :done, _}, 1_000

    RunObservers.finish(:ok)
    assert_receive {:observed, :run_end, _}, 1_000
  end

  test "a run that raises still ends observation via the try/after in Runtime.run/3", %{home: home} do
    write_recorder(home, "recorder", [:run_end])

    agent = %Pepe.Config.Agent{
      name: "run-observer-crash-test",
      system_prompt: "x",
      model: nil,
      tools: [],
      hooks: []
    }

    try do
      Pepe.Agent.Runtime.run(agent, [], model: :not_a_real_model_triggers_a_raise)
      flunk("expected Runtime.run/3 to raise for this deliberately-broken :model")
    rescue
      _ -> :ok
    end

    assert_receive {:observed, :run_end, {:run_end, :crashed}}, 1_000
  end

  # inspect(pid) (`#PID<0.147..0>`) isn't valid Elixir *source* - it's a display form, not
  # an expression a generated `.exs` can embed and re-parse. Register the test process
  # under a well-known name instead, and have the generated module look it up at call
  # time (this file's tests all run sequentially - async: false).
  @recorder_target :pepe_run_observers_test_target

  defp write_recorder(home, file, subscriptions) do
    Process.register(self(), @recorder_target)

    File.write!(Path.join([home, "plugins", "#{file}.exs"]), """
    defmodule PepeRunObserversTest.Recorder do
      @behaviour Pepe.Agent.RunObserver
      def name, do: "recorder"
      def subscriptions, do: #{inspect(subscriptions)}

      def handle_event(event, payload, _meta) do
        send(Process.whereis(#{inspect(@recorder_target)}), {:observed, event, payload})
      end
    end
    """)
  end
end
