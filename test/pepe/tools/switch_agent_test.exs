defmodule Pepe.Tools.SwitchAgentTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.SwitchAgent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_switchtool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(from, session_key \\ "test:switchtool:1"), do: %{agent: from, session_key: session_key}

  test "refuses without a calling agent in context" do
    assert {:error, msg} = SwitchAgent.run(%{"target" => "sup"}, %{session_key: "k"})
    assert msg =~ "no calling agent"
  end

  test "refuses without a session to switch" do
    from = %Agent{name: "default/admin", can_message: ["default/sup"]}
    assert {:error, msg} = SwitchAgent.run(%{"target" => "sup"}, %{agent: from})
    assert msg =~ "no session"
  end

  test "refuses an agent that isn't in can_message" do
    from = %Agent{name: "default/admin", can_message: ["default/eng"]}
    assert {:error, msg} = SwitchAgent.run(%{"target" => "sup"}, ctx(from))
    # discreet: the denial doesn't reveal the permission model
    assert msg =~ "isn't available"
    refute msg =~ "not allowed"
  end

  test "refuses an unknown agent even if routed" do
    from = %Agent{name: "default/admin", can_message: ["default/ghost"]}
    assert {:error, msg} = SwitchAgent.run(%{"target" => "ghost"}, ctx(from))
    assert msg =~ "Unknown agent"
  end

  test "refuses a cross-project target" do
    :ok = Config.add_project("acme")
    Config.put_agent(%Agent{name: "acme/eng", system_prompt: "x"})
    from = %Agent{name: "default/admin", can_message: ["acme/eng"]}

    assert {:error, msg} = SwitchAgent.run(%{"target" => "acme/eng"}, ctx(from))
    assert msg =~ "different project"
  end

  test "resolves the target case-insensitively before checking can_message" do
    Config.put_agent(%Agent{name: "default/Engenheiro", system_prompt: "eng", tools: []})
    from = %Agent{name: "default/admin", can_message: ["default/Engenheiro"]}
    key = "test:switchtool:#{System.unique_integer([:positive])}"

    {:ok, _} = SessionSupervisor.ensure(key, "default/admin")

    # The model passed the name in a different case than it's stored; this must still
    # resolve to the same agent and pass the can_message check.
    assert {:ok, _out} = SwitchAgent.run(%{"target" => "engenheiro"}, ctx(from, key))
  end

  test "authorized: hands the session to the target agent for the next turn" do
    Config.put_agent(%Agent{name: "default/eng", system_prompt: "eng", tools: []})
    Config.put_agent(%Agent{name: "default/sup", system_prompt: "sup", tools: []})
    from = %Agent{name: "default/eng", can_message: ["default/sup"]}
    key = "test:switchtool:#{System.unique_integer([:positive])}"

    {:ok, _} = SessionSupervisor.ensure(key, "default/eng")

    assert {:ok, out} = SwitchAgent.run(%{"target" => "sup"}, ctx(from, key))
    assert out =~ "sup"

    # switch_agent/2 is a cast; give it a moment to land (no turn was running, so it
    # applies immediately).
    Process.sleep(20)
    assert Session.status(key).agent == "default/sup"
  end

  test "on a Telegram session, the switch also persists - not just the in-memory session" do
    Config.put_agent(%Agent{name: "default/eng", system_prompt: "eng", tools: []})
    Config.put_agent(%Agent{name: "default/sup", system_prompt: "sup", tools: []})
    from = %Agent{name: "default/eng", can_message: ["default/sup"]}
    key = "telegram:#{System.unique_integer([:positive])}"

    {:ok, _} = SessionSupervisor.ensure(key, "default/eng")

    assert {:ok, _out} = SwitchAgent.run(%{"target" => "sup"}, ctx(from, key))

    "telegram:" <> chat = key
    assert Config.telegram_topic_agent("default", chat, nil) == "default/sup"
  end

  test "on a non-Telegram session, the switch works but there's nothing to persist" do
    Config.put_agent(%Agent{name: "default/eng", system_prompt: "eng", tools: []})
    Config.put_agent(%Agent{name: "default/sup", system_prompt: "sup", tools: []})
    from = %Agent{name: "default/eng", can_message: ["default/sup"]}
    key = "ws:#{System.unique_integer([:positive])}"

    {:ok, _} = SessionSupervisor.ensure(key, "default/eng")

    assert {:ok, _out} = SwitchAgent.run(%{"target" => "sup"}, ctx(from, key))
  end
end
