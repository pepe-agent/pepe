defmodule Pepe.Cron.SchedulerTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Cron
  alias Pepe.Cron.Scheduler

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_csch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    start_supervised!({Task.Supervisor, name: Pepe.Cron.TaskSupervisor})
    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a due job fires as a supervised task under Pepe.Cron.TaskSupervisor" do
    Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

    cron = %Cron{
      id: "sched1",
      name: "t",
      agent: "no-such-agent",
      prompt: "hi",
      schedule: "* * * * *",
      deliver: "none",
      enabled: true
    }

    Config.put_cron(cron)

    send(Scheduler, :tick)

    assert_receive {:cron_run, :started, "sched1"}, 2_000
    assert_receive {:cron_run, :finished, "sched1"}, 2_000
  end

  test "a disabled job never fires" do
    Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

    cron = %Cron{
      id: "sched2",
      name: "t",
      agent: "no-such-agent",
      prompt: "hi",
      schedule: "* * * * *",
      deliver: "none",
      enabled: false
    }

    Config.put_cron(cron)

    send(Scheduler, :tick)

    refute_receive {:cron_run, :started, "sched2"}, 200
  end
end
