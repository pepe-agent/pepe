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

  describe "a job does not run on top of itself" do
    # A model that takes its time, so a run is still going when the next slot comes round.
    defp slow_model! do
      {:ok, server} =
        Bandit.start_link(
          plug: fn conn, _ ->
            Process.sleep(2_000)

            Plug.Conn.send_resp(
              conn,
              200,
              ~s({"choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]})
            )
          end,
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      Config.put_model(%Pepe.Config.Model{
        name: "slow",
        base_url: "http://127.0.0.1:#{port}",
        api_key: "k",
        model: "m"
      })

      Config.put_agent(%Pepe.Config.Agent{name: "slowpoke", model: "slow", system_prompt: "hi", tools: []})
      :ok
    end

    defp slow_cron!(id, opts \\ []) do
      cron =
        struct(
          %Cron{
            id: id,
            name: "t",
            agent: "slowpoke",
            prompt: "hi",
            schedule: "* * * * *",
            deliver: "none",
            enabled: true
          },
          opts
        )

      Config.put_cron(cron)
      cron
    end

    # The scheduler fires each job at most once per minute, so a second attempt only happens
    # in a later minute. Clearing the guard is how a test reaches the next minute without
    # waiting for it.
    defp next_minute do
      :sys.replace_state(Scheduler, fn state -> %{state | fired: %{}} end)
    end

    test "a due job whose previous run is still going is skipped, and the skip is recorded" do
      slow_model!()
      slow_cron!("slow1")
      Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow1"}, 2_000
      assert Scheduler.running() == ["slow1"]

      next_minute()
      send(Scheduler, :tick)

      # Piling up is what must not happen: a cron here is an agent turn. It costs a model
      # call, it has side effects, and every run shares one agent workspace, so a job that
      # outgrows its schedule would be billed twice, deliver twice, and race with itself.
      assert_receive {:cron_run, :skipped, "slow1"}, 2_000
      refute_received {:cron_run, :started, "slow1"}

      # And never in silence. This entry is how you find out the job is too slow for its own
      # schedule, which is the fact that matters and the one nobody would otherwise learn.
      assert [entry | _] = Pepe.Cron.Log.tail("slow1", 5)
      assert entry["ok"] == false
      assert entry["output"] =~ "skipped"
      assert entry["output"] =~ "overlap"
    end

    test "overlap: true runs it anyway, for the job that genuinely wants it" do
      slow_model!()
      slow_cron!("slow2", overlap: true)
      Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow2"}, 2_000

      next_minute()
      send(Scheduler, :tick)

      assert_receive {:cron_run, :started, "slow2"}, 2_000
      refute_received {:cron_run, :skipped, "slow2"}
    end

    test "the claim is released when the run ends, so the next slot fires" do
      slow_model!()
      slow_cron!("slow3")
      Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow3"}, 2_000
      assert_receive {:cron_run, :finished, "slow3"}, 5_000

      # Give the DOWN a moment to land, then the job is free again.
      Process.sleep(50)
      assert Scheduler.running() == []

      next_minute()
      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow3"}, 2_000
    end

    test "the claim is released even when the run is killed outright" do
      slow_model!()
      slow_cron!("slow4")
      Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow4"}, 2_000
      assert Scheduler.running() == ["slow4"]

      # This is the whole reason the claim is released by a monitor and not by a line at the
      # end of the job. A run that crashes, hangs and is killed, or is torn down at shutdown
      # never reaches its own last line. If the claim were released there, the job would be
      # marked in flight forever and would quietly never fire again, and the only symptom
      # would be that whatever it did had stopped being done.
      [pid] = Task.Supervisor.children(Pepe.Cron.TaskSupervisor) |> Enum.to_list()
      Process.exit(pid, :kill)

      Process.sleep(100)
      assert Scheduler.running() == []

      next_minute()
      send(Scheduler, :tick)
      assert_receive {:cron_run, :started, "slow4"}, 2_000
    end
  end
end
