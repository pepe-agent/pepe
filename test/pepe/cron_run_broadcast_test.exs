defmodule Pepe.CronRunBroadcastTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Cron

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_cronbcast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "run broadcasts started and finished on the runs topic, whatever the outcome" do
    Phoenix.PubSub.subscribe(Pepe.PubSub, Pepe.Cron.runs_topic())

    # An unknown agent makes run_job error immediately (no network), but the lifecycle
    # events must still fire so a live surface can show and clear the "running" state.
    cron = %Cron{id: "c1", name: "t", agent: "no-such-agent", prompt: "hi", schedule: "0 0 * * *", deliver: "none"}

    assert {:error, _} = Pepe.Cron.run(cron, :manual)

    assert_receive {:cron_run, :started, "c1"}
    assert_receive {:cron_run, :finished, "c1"}
  end
end
