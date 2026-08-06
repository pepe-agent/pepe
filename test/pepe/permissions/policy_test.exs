defmodule Pepe.Permissions.PolicyTest do
  @moduledoc """
  A `Pepe.Permissions.Policy` plugin vetoes a tool call before any of `gate/3`'s own
  pre-approval/taint logic runs - "most restrictive wins", and unlike every other plugin
  surface in this codebase, failing closed on a crash/timeout/malformed return.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Permissions

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_policy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    agent = %Agent{name: "zak", system_prompt: "x", tools: [], auto_approve: []}
    {:ok, home: home, agent: agent}
  end

  test "with no policy plugin installed, gate/3 behaves exactly as before", %{agent: agent} do
    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx) == :allow
  end

  test "a policy plugin can veto an otherwise always-safe call", %{home: home, agent: agent} do
    write_policy(home, "blocker", "def check(_name, _args, _ctx), do: {:deny, \"company policy\"}")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("policy should short-circuit before asking") end}
    assert {:deny, "company policy"} = Permissions.gate("read_file", "{}", ctx)
  end

  test "a policy plugin can veto even an :always-approved grant", %{home: home, agent: agent} do
    write_policy(home, "blocker", "def check(_name, _args, _ctx), do: {:deny, \"no\"}")

    agent = %{agent | auto_approve: ["bash"]}
    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("policy should short-circuit before asking") end}
    assert {:deny, "no"} = Permissions.gate("bash", ~s({"command":"ls"}), ctx)
  end

  test "a crashing policy plugin fails closed - denies, does not allow", %{home: home, agent: agent} do
    write_policy(home, "crasher", "def check(_name, _args, _ctx), do: raise(\"boom\")")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask - fail-closed denies first") end}
    assert {:deny, _reason} = Permissions.gate("read_file", "{}", ctx)
  end

  test "a hanging policy plugin fails closed after its timeout, not forever", %{home: home, agent: agent} do
    write_policy(home, "hangs", "def check(_name, _args, _ctx), do: Process.sleep(:infinity)")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, _reason} = Permissions.gate("read_file", "{}", ctx)
  end

  test "a policy plugin returning a malformed shape fails closed", %{home: home, agent: agent} do
    write_policy(home, "malformed", "def check(_name, _args, _ctx), do: :not_a_valid_decision")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, _reason} = Permissions.gate("read_file", "{}", ctx)
  end

  test "an allowing policy plugin doesn't change anything - normal gate logic still applies", %{home: home, agent: agent} do
    write_policy(home, "allower", "def check(_name, _args, _ctx), do: :allow")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx) == :allow
  end

  test "a policy plugin can force a human ask on an otherwise always-approved call", %{home: home, agent: agent} do
    write_policy(home, "cautious", "def check(_name, _args, _ctx), do: {:ask, \"looks unusual\"}")

    agent = %{agent | auto_approve: ["bash"]}
    test = self()
    ctx = %{agent: agent, authorize: fn _n, _a, c -> send(test, {:asked, c[:policy_reason]}) && :once end}

    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow
    assert_receive {:asked, "looks unusual"}
  end

  test "regression: answering :always to a policy-forced ask stops it asking again for the same shape", %{home: home, agent: agent} do
    write_policy(
      home,
      "always_asks",
      "def check(\"bash\", _args, _ctx), do: {:ask, \"needs a look\"}\ndef check(_name, _args, _ctx), do: :allow"
    )

    Pepe.Config.put_agent(agent)
    test_pid = self()
    # A session_key so :always takes effect within this same test's calls immediately, via
    # SessionStore - without one, only the persisted Config write happens, and ctx.agent
    # (captured once) never sees it, same as a real second call needs a fresh session or run.
    ctx = %{agent: agent, session_key: "policy-ask-regress", authorize: fn _n, _a, _c -> send(test_pid, :asked) && :always end}

    # First call: not yet answered, must ask.
    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow
    assert_received :asked

    # Second call, same shape: the human's :always answer must stick - a policy that keeps
    # returning :ask unconditionally must not be able to make "always" meaningless.
    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow
    refute_received :asked
  end

  test "a policy-forced ask's :always answer never widens the tool's OWN ordinary grant", %{home: home, agent: agent} do
    write_policy(
      home,
      "always_asks",
      "def check(\"bash\", _args, _ctx), do: {:ask, \"needs a look\"}\ndef check(_name, _args, _ctx), do: :allow"
    )

    Pepe.Config.put_agent(agent)
    ctx = %{agent: agent, authorize: fn _n, _a, _c -> :always end}
    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow

    # Confirm the bare tool grant was NOT written - only the namespaced policy-ask one was.
    updated = Pepe.Config.get_agent(agent.name)
    refute "bash:none" in (updated.auto_approve || [])
    assert Enum.any?(updated.auto_approve || [], &String.starts_with?(&1, "policy_ask__bash"))
  end

  test "the wildcard auto_approve does NOT satisfy a policy's own ask", %{home: home, agent: agent} do
    write_policy(home, "cautious", "def check(_name, _args, _ctx), do: {:ask, \"needs a look\"}")

    agent = %{agent | auto_approve: ["*"]}
    test_pid = self()
    ctx = %{agent: agent, authorize: fn _n, _a, _c -> send(test_pid, :asked) && :once end}

    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow
    assert_received :asked
  end

  test "a :this_run answer to a policy-forced ask is respected for the rest of the tainted run", %{home: home, agent: agent} do
    write_policy(
      home,
      "cautious",
      "def check(\"bash\", _args, _ctx), do: {:ask, \"needs a look\"}\ndef check(_name, _args, _ctx), do: :allow"
    )

    on_exit(&Permissions.clear_run_grants/0)
    test_pid = self()
    ctx = %{agent: agent, tainted: true, authorize: fn _n, _a, _c -> send(test_pid, :asked) && :this_run end}

    assert Permissions.gate("bash", ~s({"command":"ls"}), ctx) == :allow
    assert_received :asked

    # Same tainted run (ctx[:tainted] still true), same shape - :this_run must stick.
    assert Permissions.gate("bash", ~s({"command":"pwd"}), ctx) == :allow
    refute_received :asked
  end

  test "a policy-forced ask on a call with NO ordinary grant also covers the tool's own future calls of that shape", %{
    home: home,
    agent: agent
  } do
    write_policy(
      home,
      "cautious",
      "def check(\"bash\", _args, _ctx), do: {:ask, \"needs a look\"}\ndef check(_name, _args, _ctx), do: :allow"
    )

    Pepe.Config.put_agent(agent)
    test_pid = self()
    ctx = %{agent: agent, session_key: "dual-write-test", authorize: fn _n, _a, _c -> send(test_pid, :asked) && :always end}

    # A command that carries real risk (writes_file) - it would ALSO need asking on its own,
    # with no policy involved at all.
    cmd = ~s({"command":"sort a.txt > b.txt"})
    assert Permissions.gate("bash", cmd, ctx) == :allow
    assert_received :asked

    # Second call, same shape: neither the policy's own question nor the tool's ordinary
    # grant should need asking again - only one human decision was ever made.
    assert Permissions.gate("bash", cmd, ctx) == :allow
    refute_received :asked
  end

  test "a policy-forced ask does NOT widen the tool's ordinary grant when it was already covered", %{home: home, agent: agent} do
    write_policy(
      home,
      "cautious",
      "def check(\"bash\", _args, _ctx), do: {:ask, \"needs a look\"}\ndef check(_name, _args, _ctx), do: :allow"
    )

    agent = %{agent | auto_approve: ["bash:writes_file"]}
    Pepe.Config.put_agent(agent)
    ctx = %{agent: agent, authorize: fn _n, _a, _c -> :always end}

    cmd = ~s({"command":"sort a.txt > b.txt"})
    assert Permissions.gate("bash", cmd, ctx) == :allow

    updated = Pepe.Config.get_agent(agent.name)
    # The pre-existing ordinary grant is untouched (not re-widened to something else) -
    # only the policy's own namespaced key was freshly added.
    assert "bash:writes_file" in (updated.auto_approve || [])
    assert Enum.any?(updated.auto_approve, &String.starts_with?(&1, "policy_ask__bash"))
  end

  test "ask with nobody to ask denies, same as the gate's own unattended rule", %{home: home, agent: agent} do
    write_policy(home, "cautious", "def check(_name, _args, _ctx), do: :ask")

    assert {:deny, _reason} = Permissions.gate("read_file", "{}", %{agent: agent})
  end

  test "deny beats ask regardless of which policy runs first", %{home: home, agent: agent} do
    write_policy(home, "asker", "def check(_name, _args, _ctx), do: :ask", "AskerA")
    write_policy(home, "denier", "def check(_name, _args, _ctx), do: {:deny, \"no\"}", "DenierB")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("deny should win, never asks") end}
    assert {:deny, "no"} = Permissions.gate("read_file", "{}", ctx)
  end

  test "multiple policies: one deny is enough regardless of order", %{home: home, agent: agent} do
    write_policy(home, "allower", "def check(_name, _args, _ctx), do: :allow", "AllowerA")
    write_policy(home, "denier", "def check(_name, _args, _ctx), do: {:deny, \"blocked\"}", "DenierB")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, "blocked"} = Permissions.gate("read_file", "{}", ctx)
  end

  test "a module exporting name/0 and check/3 for an unrelated reason is NOT treated as a policy", %{
    home: home,
    agent: agent
  } do
    # No @behaviour declaration - just happens to export the same two function names/arities,
    # e.g. a plugin's own internal validation helper. Duck-typing alone would make this a
    # global, fail-closed policy that denies bash; requiring the explicit behaviour must not.
    File.write!(Path.join([home, "plugins", "coincidence.exs"]), """
    defmodule PepePolicyTest.Coincidence do
      def name, do: "coincidence"
      def check(_a, _b, _c), do: {:deny, "unrelated function, not a real policy"}
    end
    """)

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx) == :allow
  end

  test "a policy scoped to specific agent names only applies to those agents", %{home: home, agent: agent} do
    write_policy(home, "scoped", "def check(_name, _args, _ctx), do: {:deny, \"scoped\"}")
    Pepe.Config.put_policy_scope("scoped", %{"agents" => [agent.name]})

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, "scoped"} = Permissions.gate("read_file", "{}", ctx)

    other = %{agent | name: "someone-else"}
    ctx2 = %{agent: other, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx2) == :allow
  end

  test "a policy scoped to a project applies to every agent in it, not agents elsewhere", %{home: home, agent: agent} do
    write_policy(home, "proj_scoped", "def check(_name, _args, _ctx), do: {:deny, \"project scoped\"}")
    Pepe.Config.put_policy_scope("proj_scoped", %{"projects" => ["acme"]})

    in_project = %{agent | name: "acme/support"}
    ctx = %{agent: in_project, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, "project scoped"} = Permissions.gate("read_file", "{}", ctx)

    outside = %{agent | name: "other/support"}
    ctx2 = %{agent: outside, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx2) == :allow
  end

  test "an unscoped policy still applies to every agent, unchanged from before scoping existed", %{home: home, agent: agent} do
    write_policy(home, "everyone", "def check(_name, _args, _ctx), do: {:deny, \"no scope\"}")

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert {:deny, "no scope"} = Permissions.gate("read_file", "{}", ctx)
  end

  test "clearing a policy's scope makes it apply everywhere again", %{home: home, agent: agent} do
    write_policy(home, "scoped2", "def check(_name, _args, _ctx), do: {:deny, \"scoped2\"}")
    Pepe.Config.put_policy_scope("scoped2", %{"agents" => ["only-this-one"]})

    ctx = %{agent: agent, authorize: fn _, _, _ -> flunk("should not ask") end}
    assert Permissions.gate("read_file", "{}", ctx) == :allow

    Pepe.Config.delete_policy_scope("scoped2")
    assert {:deny, "scoped2"} = Permissions.gate("read_file", "{}", ctx)
  end

  describe "veto_run/3 - message-level gate, before any tool call" do
    test "a policy with only check/3 (no check_run/3) doesn't participate - allows", %{home: home, agent: agent} do
      write_policy(home, "tool_only", "def check(_name, _args, _ctx), do: {:deny, \"should never be consulted here\"}")
      assert Pepe.Permissions.Policy.veto_run(agent, "hello", %{}) == :allow
    end

    test "a policy's check_run/3 can deny a run before it starts", %{home: home, agent: agent} do
      write_policy(
        home,
        "run_denier",
        "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: {:deny, \"banned sender\"}"
      )

      assert {:deny, "banned sender"} = Pepe.Permissions.Policy.veto_run(agent, "hello", %{})
    end

    test "a policy's check_run/3 allowing lets the run proceed", %{home: home, agent: agent} do
      write_policy(home, "run_allower", "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: :allow")
      assert Pepe.Permissions.Policy.veto_run(agent, "hello", %{}) == :allow
    end

    test "check_run/3's :ask is folded like a deny - there is no pre-run interactive ask yet", %{home: home, agent: agent} do
      write_policy(
        home,
        "run_asker",
        "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: {:ask, \"needs a human\"}"
      )

      assert {:ask, "needs a human"} = Pepe.Permissions.Policy.veto_run(agent, "hello", %{})
    end

    test "a crashing check_run/3 fails closed, same as check/3 does", %{home: home, agent: agent} do
      write_policy(
        home,
        "run_crasher",
        "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: raise(\"boom\")"
      )

      assert {:deny, _reason} = Pepe.Permissions.Policy.veto_run(agent, "hello", %{})
    end

    test "policy_scope also filters check_run/3, not just check/3", %{home: home, agent: agent} do
      write_policy(
        home,
        "run_scoped",
        "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: {:deny, \"scoped run policy\"}"
      )

      Pepe.Config.put_policy_scope("run_scoped", %{"agents" => ["someone-else"]})
      assert Pepe.Permissions.Policy.veto_run(agent, "hello", %{}) == :allow

      Pepe.Config.put_policy_scope("run_scoped", %{"agents" => [agent.name]})
      assert {:deny, "scoped run policy"} = Pepe.Permissions.Policy.veto_run(agent, "hello", %{})
    end
  end

  describe "Runtime.run/3 - a blocked run never reaches the model" do
    test "check_run/3 denying stops the run before any model call", %{home: home} do
      write_policy(
        home,
        "runtime_denier",
        "def check(_n, _a, _c), do: :allow\ndef check_run(_agent, _msg, _ctx), do: {:deny, \"blocked at the door\"}"
      )

      agent = %Agent{
        name: "runtime-test",
        system_prompt: "x",
        tools: [],
        model: %Pepe.Config.Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"}
      }

      assert {:error, {:policy_denied, "blocked at the door"}} =
               Pepe.Agent.Runtime.run(agent, [Pepe.LLM.Message.user("hi")], model: agent.model)
    end
  end

  defp write_policy(home, file, body, module_suffix \\ nil) do
    mod = "PepePolicyTest.#{module_suffix || Macro.camelize(file)}"

    File.write!(Path.join([home, "plugins", "#{file}.exs"]), """
    defmodule #{mod} do
      @behaviour Pepe.Permissions.Policy
      def name, do: "#{file}"
      #{body}
    end
    """)
  end
end
