defmodule Pepe.Tools.ScheduleTaskTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.ScheduleTask

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sched_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(session_key \\ nil) do
    %{agent: %Agent{name: "zak"}, session_key: session_key}
  end

  test "creates a task, defaulting delivery to the originating chat" do
    assert {:ok, out} =
             ScheduleTask.run(
               %{
                 "action" => "create",
                 "name" => "Daily XML",
                 "prompt" => "Check the XML load.",
                 "schedule" => "0 8 * * *",
                 "timezone" => "America/Sao_Paulo"
               },
               ctx("telegram:123")
             )

    assert out =~ "created"

    [cron] = Config.crons()
    assert cron.name == "Daily XML"
    assert cron.agent == "zak"
    assert cron.timezone == "America/Sao_Paulo"
    # No explicit deliver -> reports back to the chat it was created in.
    assert cron.deliver == "telegram:123"
  end

  test "an empty deliver string falls back to the originating chat (not nowhere)" do
    assert {:ok, _} =
             ScheduleTask.run(
               %{
                 "action" => "create",
                 "name" => "Reminder",
                 "prompt" => "ping",
                 "schedule" => "30 23 * * *",
                 "deliver" => ""
               },
               ctx("telegram:842064390")
             )

    [cron] = Config.crons()
    # `deliver: ""` used to survive `"" || default` and deliver nowhere.
    assert cron.deliver == "telegram:842064390"
  end

  test "rejects an invalid schedule" do
    assert {:error, msg} =
             ScheduleTask.run(
               %{"action" => "create", "name" => "x", "prompt" => "y", "schedule" => "nope"},
               ctx()
             )

    assert msg =~ "invalid cron expression"
    assert Config.crons() == []
  end

  test "list, disable and remove operate on stored tasks" do
    ScheduleTask.run(
      %{
        "action" => "create",
        "name" => "Job A",
        "prompt" => "p",
        "schedule" => "0 8 * * *",
        "deliver" => "none"
      },
      ctx()
    )

    assert {:ok, listing} = ScheduleTask.run(%{"action" => "list"}, ctx())
    assert listing =~ "Job A"

    id = hd(Config.crons()).id
    assert {:ok, _} = ScheduleTask.run(%{"action" => "disable", "id" => id}, ctx())
    refute Config.get_cron(id).enabled

    assert {:ok, _} = ScheduleTask.run(%{"action" => "remove", "id" => id}, ctx())
    assert Config.crons() == []
  end
end
