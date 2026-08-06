defmodule Pepe.Slots.GuardTest do
  @moduledoc """
  "Failures never block replies": a misbehaving non-default occupant degrades to the
  default for that one call - it never raises out to the caller. Exercised against the
  real `memory` slot for the same reason as `Pepe.SlotsTest`.
  """
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_slots_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.Slots.Health.clear("memory")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Pepe.Slots.Health.clear("memory")
    end)

    {:ok, home: home}
  end

  test "the default occupant's own result passes straight through" do
    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "nothing to find", []])
  end

  test "a crashing occupant degrades to the default's answer, not a raised exception", %{home: home} do
    write_plugin(home, "boom", """
    def search(_agent, _query, _opts), do: raise("boom")
    """)

    Pepe.Config.put_slot("memory", "boom")

    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []])
  end

  test "an occupant that never returns degrades once the slot's timeout fires", %{home: home} do
    write_plugin(home, "slow", """
    def search(_agent, _query, _opts) do
      Process.sleep(:infinity)
    end
    """)

    Pepe.Config.put_slot("memory", "slow")

    # The memory slot's own timeout (3s) governs this - no sleeping past it in the test,
    # just confirming the call returns (rather than hanging) with the default's answer.
    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []])
  end

  test "an occupant returning a shape outside {:ok,_}|{:error,_} degrades to the default", %{home: home} do
    write_plugin(home, "malformed", """
    def search(_agent, _query, _opts), do: :not_a_valid_return
    """)

    Pepe.Config.put_slot("memory", "malformed")

    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []])
  end

  test "even a non-default occupant's own clean {:error, _} degrades to the default", %{home: home} do
    write_plugin(home, "erroring", """
    def search(_agent, _query, _opts), do: {:error, :deliberately_unavailable}
    """)

    Pepe.Config.put_slot("memory", "erroring")

    # One simple rule for a non-default occupant: only its own {:ok, _} is trusted.
    # Anything else - a crash, a timeout, a malformed shape, or its own reported error -
    # degrades to the default, so the caller never has to special-case "the plugin is
    # configured but currently broken" differently from "the plugin crashed".
    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []])
  end

  test "a malformed payload inside a clean {:ok, _} still degrades to the default", %{home: home} do
    write_plugin(home, "bad_payload", """
    def search(_agent, _query, _opts), do: {:ok, ["not a Hit struct"]}
    """)

    Pepe.Config.put_slot("memory", "bad_payload")

    # The tuple shape alone (`{:ok, _}`) isn't proof the payload inside it is what the
    # caller actually expects - Guard also checks it against the slot's own validator.
    assert {:ok, []} = Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []])
  end

  test "a failing occupant is recorded in Pepe.Slots.Health, cleared on the next clean success", %{home: home} do
    write_plugin(home, "flaky", """
    def search(_agent, query, _opts) do
      if query == "fail", do: raise("boom"), else: {:ok, []}
    end
    """)

    Pepe.Config.put_slot("memory", "flaky")

    assert Pepe.Slots.Health.last_failure("memory") == nil

    Pepe.Slots.Guard.call("memory", :search, ["nobody", "fail", []])
    assert %{reason: {:crashed, _}} = Pepe.Slots.Health.last_failure("memory")

    Pepe.Slots.Guard.call("memory", :search, ["nobody", "ok", []])
    assert Pepe.Slots.Health.last_failure("memory") == nil
  end

  test "a caller that never comes back doesn't orphan the occupant's Task past the slot timeout", %{home: home} do
    write_plugin(home, "hangs", """
    def search(_agent, _query, _opts), do: Process.sleep(:infinity)
    """)

    Pepe.Config.put_slot("memory", "hangs")

    # A caller that spawns the guarded call and dies before ever coming back to
    # yield/shut it down itself - the occupant's Task must still wind itself down within
    # the slot's own timeout (3s for "memory"), because it enforces that deadline on
    # itself, not only via the caller coming back to collect the result.
    {caller, ref} = spawn_monitor(fn -> Pepe.Slots.Guard.call("memory", :search, ["nobody", "anything", []]) end)

    # Wait for BOTH of this call's Tasks to exist before killing the caller - the outer
    # (self-enforcing) Task and the inner one actually running the occupant's call. Waiting
    # for just a non-empty list can catch only the outer: there's a real window, between the
    # supervisor registering it and it spawning the inner Task, where children/1 already
    # returns a single-element list. Snapshotting there would make the assertion below check
    # only that the outer pid dies - which it always does, since it self-enforces regardless
    # of the inner - silently not proving anything about the actual regression (an orphaned
    # INNER Task) this test exists to catch. `Pepe.Slots.TaskSupervisor` is a single
    # suite-wide process, so snapshot the specific pids this call spawned rather than
    # asserting the whole list is non-empty - a different concurrently-running (or
    # just-finished) test touching the same supervisor would otherwise make this assertion
    # mean nothing.
    spawned = eventually_children(2, 2_000)
    assert match?([_, _ | _], spawned)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}

    # The self-enforced deadline is the 3s slot timeout. Polling instead of one fixed
    # sleep-then-check: a single point-in-time assertion flaked under real load (a busy
    # predeploy run, 5s wasn't always enough) because it conflates "bounded" (what this
    # test actually proves) with "bounded by exactly this many seconds on this machine
    # right now" (which it doesn't, and shouldn't have to). The ceiling here is a generous
    # backstop against a genuine regression, not the deadline itself. Checking that these
    # SPECIFIC pids died (not that the shared supervisor's whole child list is empty) is
    # what makes this immune to an unrelated test's own, unrelated, legitimate use of the
    # same suite-wide supervisor overlapping in time.
    assert eventually(fn -> Enum.all?(spawned, &(not Process.alive?(&1))) end, 15_000)
  end

  defp eventually_children(_min, remaining_ms) when remaining_ms <= 0, do: []

  defp eventually_children(min, remaining_ms) do
    case Task.Supervisor.children(Pepe.Slots.TaskSupervisor) do
      pids when length(pids) >= min ->
        pids

      _too_few ->
        Process.sleep(200)
        eventually_children(min, remaining_ms - 200)
    end
  end

  defp eventually(_check, remaining_ms) when remaining_ms <= 0, do: false

  defp eventually(check, remaining_ms) do
    if check.() do
      true
    else
      Process.sleep(200)
      eventually(check, remaining_ms - 200)
    end
  end

  defp write_plugin(home, name, body) do
    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule PepeGuardTest.#{Macro.camelize(name)} do
      @behaviour Pepe.Memory.Backend
      def name, do: "#{name}"
      def slot, do: "memory"
      #{body}
    end
    """)
  end
end
