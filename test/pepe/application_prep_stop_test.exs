defmodule Pepe.ApplicationPrepStopTest do
  use ExUnit.Case, async: false

  # prep_stop starts draining, which is global; leave the gate open for the tests after this one.
  setup do
    Pepe.Drain.reset()
    on_exit(&Pepe.Drain.reset/0)
  end

  test "prep_stop drains in-flight cron tasks before returning" do
    start_supervised!({Task.Supervisor, name: Pepe.Cron.TaskSupervisor})

    test_pid = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(Pepe.Cron.TaskSupervisor, fn ->
        Process.sleep(150)
        send(test_pid, :task_ran_to_completion)
      end)

    assert Pepe.Application.prep_stop(:some_state) == :some_state
    assert_received :task_ran_to_completion
    assert Task.Supervisor.children(Pepe.Cron.TaskSupervisor) == []
  end

  test "prep_stop is a no-op when no cron scheduler was ever started" do
    assert Pepe.Application.prep_stop(:some_state) == :some_state
  end

  test "prep_stop stops admitting new work, and waits for a turn that is already running" do
    {:ok, _} = Application.ensure_all_started(:pepe)
    refute Pepe.Drain.draining?()

    test_pid = self()

    turn =
      spawn(fn ->
        Process.sleep(200)
        send(test_pid, :turn_finished)
      end)

    Pepe.Drain.enter(turn)

    assert Pepe.Application.prep_stop(:some_state) == :some_state
    assert Pepe.Drain.draining?()
    assert_received :turn_finished
    assert Pepe.Drain.in_flight() == 0
  end
end
