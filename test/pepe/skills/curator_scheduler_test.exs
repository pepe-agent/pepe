defmodule Pepe.Skills.Curator.SchedulerTest do
  use ExUnit.Case, async: false

  alias Pepe.Skills.Curator.Scheduler
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_curator_sched_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    start_supervised!({Task.Supervisor, name: Pepe.Skills.Curator.TaskSupervisor})
    pid = start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{pid: pid}
  end

  # Wait for every curator run in flight to finish, without sleeping.
  defp await_runs do
    for child <- Task.Supervisor.children(Pepe.Skills.Curator.TaskSupervisor) do
      ref = Process.monitor(child)
      assert_receive {:DOWN, ^ref, :process, ^child, _}, 5_000
    end
  end

  defp long_ago, do: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -30 * 86_400))

  test "a tick that finds the curator due runs it once", %{pid: pid} do
    State.update(%{"last_run_at" => long_ago()})

    send(pid, :tick)
    :sys.get_state(pid)
    await_runs()

    assert State.load()["run_count"] == 1
  end

  test "a tick does nothing when the curator is off", %{pid: pid} do
    State.update(%{"last_run_at" => long_ago()})
    :ok = Settings.put("enabled", false)

    send(pid, :tick)
    :sys.get_state(pid)
    await_runs()

    assert State.load()["run_count"] == 0
  end
end
