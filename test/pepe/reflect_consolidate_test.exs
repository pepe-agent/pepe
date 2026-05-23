defmodule Pepe.ReflectConsolidateTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Reflect
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Config.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_consolidate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "x", model: "mock", tools: []})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "schedule_auto creates a managed consolidate cron; unschedule removes it" do
    refute Reflect.auto?("assistant")

    {:ok, cron} = Reflect.schedule_auto("assistant")
    assert cron.kind == "consolidate"
    assert cron.id == "learn:assistant"
    assert cron.schedule == Reflect.default_schedule()
    assert cron.deliver == "none"
    assert Reflect.auto?("assistant")

    # persisted and round-trips through config
    assert %Cron{kind: "consolidate", agent: "default/assistant"} = Config.get_cron("learn:assistant")

    :ok = Reflect.unschedule_auto("assistant")
    refute Reflect.auto?("assistant")
  end

  test "schedule_auto honors a custom schedule" do
    {:ok, cron} = Reflect.schedule_auto("assistant", schedule: "0 */6 * * *")
    assert cron.schedule == "0 */6 * * *"
  end

  test "consolidate runs the restricted reviewer and returns a summary" do
    assert {:ok, summary, _messages} = Pepe.Agent.consolidate("assistant")
    assert is_binary(summary)
  end

  test "a consolidate cron dispatches to the consolidation pass and is recorded" do
    {:ok, cron} = Reflect.schedule_auto("assistant")

    assert {:ok, output} = Pepe.Cron.run(cron, :manual)
    assert is_binary(output)

    # the run was recorded on the cron
    assert %Cron{last_result: r} = Config.get_cron("learn:assistant")
    assert r != nil
  end
end
