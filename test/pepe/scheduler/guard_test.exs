defmodule Pepe.Scheduler.GuardTest do
  @moduledoc """
  The busy-tracking + monitored-task machinery shared by every in-app scheduler
  (`Watch`/`Commitments`/`Board`/`Cron`/`Insight`) - pure unit tests, no GenServer needed
  since `Guard` is a plain value.
  """

  use ExUnit.Case, async: true

  alias Pepe.Scheduler.Guard

  setup do
    # start_supervised!/1, not a bare Task.Supervisor.start_link/1: a named process left to
    # its own termination timing can still be shutting down when the next test's setup runs,
    # since it's merely linked (not tracked by ExUnit), making a fresh start_link(name: ...)
    # flake with {:error, {:already_started, pid}} - start_supervised!/1 is what AGENTS.md
    # asks for precisely to avoid this: ExUnit stops it synchronously before the next test.
    pid = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    %{sup: pid}
  end

  test "a fresh guard has nothing busy" do
    guard = Guard.new()
    refute Guard.busy?(guard, "x")
    assert Guard.running_ids(guard) == []
  end

  test "start/5 marks the id busy and running_ids reflects it" do
    guard = Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "job1", fn -> Process.sleep(5_000) end, "test")
    assert Guard.busy?(guard, "job1")
    assert Guard.running_ids(guard) == ["job1"]
    refute Guard.busy?(guard, "job2")
  end

  test "down/2 releases the id and returns its default payload (the id itself)" do
    guard = Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "job1", fn -> :ok end, "test")
    [ref] = Map.keys(guard.refs)

    assert {"job1", "job1", guard} = Guard.down(guard, ref)
    refute Guard.busy?(guard, "job1")
    assert Guard.running_ids(guard) == []
  end

  test "down/2 returns a custom down_payload separate from the busy-tracking id" do
    payload = {:claimed_by, "agent-1", 12_345}
    guard = Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "card1", payload, fn -> :ok end, "test")
    [ref] = Map.keys(guard.refs)

    assert {"card1", ^payload, guard} = Guard.down(guard, ref)
    refute Guard.busy?(guard, "card1")
  end

  test "down/2 on an unrelated ref returns :not_found and leaves the guard untouched" do
    guard = Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "job1", fn -> Process.sleep(5_000) end, "test")
    unrelated_ref = make_ref()

    assert Guard.down(guard, unrelated_ref) == :not_found
    assert Guard.busy?(guard, "job1")
  end

  test "down/2 called twice for the same ref is idempotent - the second call is :not_found" do
    guard = Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "job1", fn -> :ok end, "test")
    [ref] = Map.keys(guard.refs)

    assert {"job1", "job1", guard} = Guard.down(guard, ref)
    assert Guard.down(guard, ref) == :not_found
  end

  test "two different ids can be busy at once, independently released" do
    guard =
      Guard.new()
      |> Guard.start(__MODULE__.TaskSupervisor, "a", fn -> Process.sleep(5_000) end, "test")
      |> Guard.start(__MODULE__.TaskSupervisor, "b", fn -> Process.sleep(5_000) end, "test")

    assert Guard.busy?(guard, "a")
    assert Guard.busy?(guard, "b")
    assert Enum.sort(Guard.running_ids(guard)) == ["a", "b"]

    [ref_a] = for {ref, {"a", _}} <- guard.refs, do: ref
    assert {"a", "a", guard} = Guard.down(guard, ref_a)
    refute Guard.busy?(guard, "a")
    assert Guard.busy?(guard, "b")
  end

  test "an overlapping second start for the same id is not lost when the first run's :DOWN arrives" do
    guard = Guard.new()
    guard = Guard.start(guard, __MODULE__.TaskSupervisor, "cron1", fn -> :ok end, "test")
    [ref1] = Map.keys(guard.refs)

    # A second run for the same id starts before the first one's :DOWN is handled - the
    # scenario Pepe.Cron.Scheduler's overlap: true allows for.
    guard = Guard.start(guard, __MODULE__.TaskSupervisor, "cron1", fn -> Process.sleep(5_000) end, "test")
    assert map_size(guard.refs) == 2

    # The FIRST run's :DOWN must not erase the busy marker the second (still-live) run owns.
    {"cron1", "cron1", guard} = Guard.down(guard, ref1)
    assert Guard.busy?(guard, "cron1")
    assert Guard.running_ids(guard) == ["cron1"]
  end

  test "start/5 raises with a clear error when fun is not a 0-arity function" do
    # Process.get/2's return type is opaque to the compiler, unlike a literal string - the
    # point here is the *runtime* is_function(fun, 0) guard, not a static type mismatch the
    # type checker would already catch on its own before this ever ran.
    not_a_function = Process.get(:no_such_key, "not a function")

    assert_raise FunctionClauseError, fn ->
      Guard.start(Guard.new(), __MODULE__.TaskSupervisor, "job1", not_a_function, "test")
    end
  end

  test "start/5 logs and leaves the guard unchanged when the supervisor declines to start the task" do
    # DynamicSupervisor-backed max_children: 0 makes start_child/2 return {:error, :max_children}
    # without raising - the "supervisor is alive but declines" path start/5 is documented to
    # degrade around, distinct from a dead/unregistered supervisor (which still raises).
    {:ok, capped} = Task.Supervisor.start_link(max_children: 0)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        guard = Guard.start(Guard.new(), capped, "job1", fn -> :ok end, "test")
        refute Guard.busy?(guard, "job1")
        assert guard == Guard.new()
      end)

    assert log =~ "test \"job1\": could not start a run"
  end
end
