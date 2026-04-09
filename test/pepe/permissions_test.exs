defmodule Pepe.PermissionsTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Permissions
  alias Pepe.Permissions.SessionStore

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_perm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    agent = %Agent{name: "zak", system_prompt: "x", tools: [], auto_approve: []}
    {:ok, agent: agent}
  end

  test "read-only tools never need approval" do
    refute Permissions.requires_approval?("read_file")
    refute Permissions.requires_approval?("list_dir")
    assert Permissions.requires_approval?("bash")
    assert Permissions.requires_approval?("write_file")
    # Unknown/plugin tools default to requiring approval.
    assert Permissions.requires_approval?("some_plugin_tool")
  end

  test "safe tools run without ever asking", %{agent: agent} do
    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx) == :allow
  end

  test "with no authorizer, risky tools still run (non-interactive surfaces)", %{agent: agent} do
    assert Permissions.gate("bash", "{}", %{agent: agent}) == :allow
  end

  test "a \"*\" auto_approve grant runs every risky tool without asking (omnipotent agent)" do
    omni = %Agent{name: "boss", auto_approve: ["*"]}
    ctx = %{agent: omni, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("bash", "{}", ctx) == :allow
    assert Permissions.gate("write_file", "{}", ctx) == :allow
    assert Permissions.gate("some_plugin_tool", "{}", ctx) == :allow
  end

  test "deny refuses and is never remembered", %{agent: agent} do
    ctx = %{agent: agent, session_key: "s1", authorize: fn _, _, _ -> :deny end}
    assert Permissions.gate("bash", "{}", ctx) == :deny
    # Asked again next time (not remembered).
    parent = self()
    ctx2 = %{ctx | authorize: fn _, _, _ -> send(parent, :asked) && :deny end}
    assert Permissions.gate("bash", "{}", ctx2) == :deny
    assert_received :asked
  end

  test "once allows this call only, remembers nothing", %{agent: agent} do
    ctx = %{agent: agent, session_key: "s2", authorize: fn _, _, _ -> :once end}
    assert Permissions.gate("bash", "{}", ctx) == :allow
    refute SessionStore.member?("s2", "bash")

    assert Config.get_agent("zak") == nil or
             "bash" not in (Config.get_agent("zak").auto_approve || [])
  end

  test "session grant is remembered for the key and cleared on reset", %{agent: agent} do
    Config.put_agent(agent)
    asks = :counters.new(1, [])

    authorize = fn _, _, _ ->
      :counters.add(asks, 1, 1)
      :session
    end

    key = "telegram:42"
    ctx = %{agent: agent, session_key: key, authorize: authorize}

    assert Permissions.gate("bash", "{}", ctx) == :allow
    # Second call is pre-approved - the authorizer is not invoked again.
    assert Permissions.gate("bash", "{}", ctx) == :allow
    assert :counters.get(asks, 1) == 1
    assert SessionStore.member?(key, "bash")

    SessionStore.clear(key)
    refute SessionStore.member?(key, "bash")
  end

  test "always grant persists on the agent in config", %{agent: agent} do
    Config.put_agent(agent)
    ctx = %{agent: agent, session_key: "s3", authorize: fn _, _, _ -> :always end}

    assert Permissions.gate("write_file", "{}", ctx) == :allow
    assert "write_file" in Config.get_agent("zak").auto_approve

    # A fresh ctx carrying the reloaded agent is pre-approved, no asking.
    reloaded = Config.get_agent("zak")
    ctx2 = %{agent: reloaded, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("write_file", "{}", ctx2) == :allow
  end

  test "always also takes effect immediately within the same run, not just the next one",
       %{agent: agent} do
    Config.put_agent(agent)
    ctx = %{agent: agent, session_key: "s4", authorize: fn _, _, _ -> :always end}

    assert Permissions.gate("bash", "{}", ctx) == :allow

    # Still the *same* (stale) ctx.agent, as a real agentic loop would reuse for the
    # rest of this turn - a second bash call must not re-prompt.
    ctx_still_stale = %{ctx | authorize: fn _, _, _ -> flunk("should not ask again") end}
    assert Permissions.gate("bash", "{}", ctx_still_stale) == :allow
  end
end
