defmodule Pepe.HeartbeatSessionTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Heartbeat.Events

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    home = Path.join(System.tmp_dir!(), "pepe_hbs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Config.Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "x",
      model: "mock-model"
    })

    Config.put_agent(%Config.Agent{name: "pulsar", system_prompt: "x", tools: [], model: "mock"})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    key = "test:hb:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "pulsar")
    %{key: key}
  end

  test "a quiet pulse returns :silent and doesn't grow the visible history", %{key: key} do
    before = Session.history(key)
    assert Session.heartbeat(key) == :silent
    assert Session.history(key) == before
  end

  test "a pulse with something worth saying speaks up and joins history", %{key: key} do
    Events.push(key, "TRIGGER_SPEAK: the deploy just failed")

    assert {:ok, text} = Session.heartbeat(key)
    assert text == "Something happened!"

    history = Session.history(key)
    assert Enum.any?(history, &(&1["role"] == "assistant" and &1["content"] == text))
    # The internal pulse prompt itself never becomes a visible "user" turn.
    refute Enum.any?(
             history,
             &(&1["role"] == "user" and (&1["content"] || "") =~ "heartbeat check")
           )
  end

  test "a pulse still works normally right after an ordinary turn completes", %{key: key} do
    {:ok, _reply} = Session.chat(key, "hello")
    assert Session.heartbeat(key) == :silent
  end

  test "end_session cast while idle resets the context now, not on the next unrelated turn", %{key: key} do
    {:ok, _reply} = Session.chat(key, "hello")
    assert Enum.any?(Session.history(key), &(&1["role"] == "user"))

    # `end_session` is a cast. Fired from an inline heartbeat/aside (or any time no normal turn is
    # running), it used to only set `reset_pending`, which then wiped the NEXT normal turn's context.
    # It must apply the reset immediately instead. The next synchronous call is processed after the
    # cast, so a cleared history here proves it did not linger.
    Session.end_session(key)
    refute Enum.any?(Session.history(key), &(&1["role"] == "user"))
  end
end
