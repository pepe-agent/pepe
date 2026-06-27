defmodule Pepe.Agent.SetAgentKeepsHistoryTest do
  @moduledoc """
  A per-topic agent binding re-asserts its agent on every turn to stay authoritative. That must
  NOT wipe the conversation - otherwise a follow-up ("which are they?") arrives with no context and
  the model answers against the system prompt instead of the prior turn. Only a genuine *switch* to
  a different agent starts fresh.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.LLM.Message

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_setagent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Pepe.Config.Agent{name: "eng", system_prompt: "eng", tools: [], max_iterations: 5})
    Config.put_agent(%Pepe.Config.Agent{name: "sup", system_prompt: "sup", tools: [], max_iterations: 5})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:setagent:#{System.unique_integer([:positive])}"}
  end

  test "re-asserting the same agent keeps the conversation; switching resets it", %{key: key} do
    {:ok, _} = SessionSupervisor.ensure(key, "eng")

    convo = [
      Message.system("eng"),
      Message.user("quantas empresas?"),
      Message.assistant("6 empresas.")
    ]

    :ok = Session.seed(key, %{messages: convo, model_override: nil, pii_map: []})

    # Re-asserting the SAME agent (what a per-topic binding does every turn) keeps the history.
    :ok = Session.set_agent(key, "eng")
    history = Session.history(key)
    assert [_system, _user, _assistant] = history
    assert Enum.any?(history, &(&1["content"] == "6 empresas."))

    # Switching to a DIFFERENT agent starts fresh on purpose.
    :ok = Session.set_agent(key, "sup")
    assert [%{"role" => "system"}] = Session.history(key)
  end

  test "re-asserting under the canonical handle a turn leaves behind keeps history", %{key: key} do
    # After a turn, the session's agent_name is the CANONICAL handle ("default/eng"), while a
    # per-topic binding re-asserts the raw string the user typed ("eng"). A bare-string compare
    # would treat those as different agents and wipe the history every turn - this is the exact
    # hole that made "quais são?" arrive with no context. Start the session under the canonical
    # handle (what run_done leaves) and re-assert the raw one (what the binding sends).
    canonical = Config.get_agent("eng").name
    assert canonical != "eng", "expected the handle to qualify with a project (e.g. default/eng)"

    {:ok, _} = SessionSupervisor.ensure(key, canonical)

    :ok =
      Session.seed(key, %{
        messages: [Message.system("eng"), Message.user("quantas empresas?"), Message.assistant("6 empresas.")],
        model_override: nil,
        pii_map: []
      })

    :ok = Session.set_agent(key, "eng")

    history = Session.history(key)
    assert [_system, _user, _assistant] = history
    assert Enum.any?(history, &(&1["content"] == "6 empresas."))
  end

  test "/new (reset) clears the conversation back to the system prompt", %{key: key} do
    {:ok, _} = SessionSupervisor.ensure(key, "eng")

    :ok =
      Session.seed(key, %{
        messages: [Message.system("eng"), Message.user("oi"), Message.assistant("olá")],
        model_override: nil,
        pii_map: []
      })

    assert [_system, _user, _assistant] = Session.history(key)

    :ok = Session.reset(key)
    assert [%{"role" => "system"}] = Session.history(key)
  end
end
