defmodule Pepe.ApplicationPrepStopTest do
  use ExUnit.Case, async: false

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
end
