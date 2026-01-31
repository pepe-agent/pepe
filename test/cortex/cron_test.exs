defmodule Cortex.CronTest do
  use ExUnit.Case, async: false

  alias Cortex.Config
  alias Cortex.Config.Cron
  alias Cortex.Cron.Log

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_cron_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp sample(overrides \\ %{}) do
    base = %Cron{
      id: "daily",
      name: "Daily check",
      agent: "assistant",
      prompt: "Do the daily check.",
      schedule: "0 8 * * *",
      timezone: "America/Sao_Paulo",
      deliver: "none",
      enabled: true
    }

    struct(base, overrides)
  end

  test "put/get/delete cron round-trips through config" do
    Config.put_cron(sample())

    got = Config.get_cron("daily")
    assert got.name == "Daily check"
    assert got.timezone == "America/Sao_Paulo"
    assert got.enabled

    assert Enum.map(Config.crons(), & &1.id) == ["daily"]

    Config.delete_cron("daily")
    assert Config.get_cron("daily") == nil
    assert Config.crons() == []
  end

  test "due? matches the scheduled minute in the cron's own timezone" do
    cron = sample()
    assert Cortex.Cron.due?(cron, ~N[2026-07-01 08:00:00])
    refute Cortex.Cron.due?(cron, ~N[2026-07-01 09:00:00])
  end

  test "next_run is a DateTime in the cron's timezone" do
    dt = Cortex.Cron.next_run(sample())
    assert %DateTime{} = dt
    assert dt.time_zone == "America/Sao_Paulo"
    assert dt.hour == 8 and dt.minute == 0
  end

  test "an invalid schedule never fires and yields no next run" do
    cron = sample(%{schedule: "not a cron"})
    refute Cortex.Cron.due?(cron, ~N[2026-07-01 08:00:00])
    assert Cortex.Cron.next_run(cron) == nil
  end

  test "run log appends newest-first and survives delete" do
    Log.append("daily", :manual, true, "first")
    Log.append("daily", :scheduler, false, "second")

    [latest, older] = Log.tail("daily", 10)
    assert latest["output"] == "second"
    assert latest["ok"] == false
    assert latest["source"] == "scheduler"
    assert older["output"] == "first"

    Log.delete("daily")
    assert Log.tail("daily", 10) == []
  end

  test "missed?/1 detects a just-missed slot once, anchored to last_run" do
    # An hourly job scheduled for the minute that just passed (~60s ago): well inside
    # the grace window (half of 1h = 30min), and last_run predates the slot → missed.
    now = DateTime.now!("Etc/UTC")
    prev_minute = now |> DateTime.add(-60, :second) |> Map.fetch!(:minute)
    cron = sample(%{schedule: "#{prev_minute} * * * *", timezone: "Etc/UTC", last_run: 0})
    assert {true, _slot} = Cortex.Cron.missed?(cron)

    # After recording a run "now", nothing is missed anymore.
    ran =
      sample(%{
        schedule: "#{prev_minute} * * * *",
        timezone: "Etc/UTC",
        last_run: System.os_time(:second)
      })

    refute Cortex.Cron.missed?(ran)
  end

  test "missed?/1 is false outside the grace window" do
    # Daily job whose slot was ~half a day ago: grace caps at 2h → not missed.
    now = DateTime.now!("Etc/UTC")
    far_hour = rem(now.hour + 12, 24)
    cron = sample(%{schedule: "0 #{far_hour} * * *", timezone: "Etc/UTC", last_run: 0})
    refute Cortex.Cron.missed?(cron)
  end

  test "deliver \"none\" is a no-op, unknown targets go to the log" do
    assert Cortex.Cron.deliver("none", "anything") == :ok
    assert Cortex.Cron.deliver("log", "goes to logger") == :ok
  end
end
