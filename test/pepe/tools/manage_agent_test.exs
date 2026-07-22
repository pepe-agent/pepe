defmodule Pepe.Tools.ManageAgentTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.ManageAgent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mga_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "vendas", system_prompt: "x", tools: ["read_file"]})
    Config.put_agent(%Agent{name: "rh", system_prompt: "x", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx(can_manage), do: %{agent: %Agent{name: "admin", can_manage: can_manage}}

  describe "can_manage?/2 semantics" do
    test "nil = itself only" do
      a = %Agent{name: "admin", can_manage: nil}
      assert Config.can_manage?(a, "admin")
      refute Config.can_manage?(a, "vendas")
    end

    test "[] = nobody, not even itself" do
      a = %Agent{name: "admin", can_manage: []}
      refute Config.can_manage?(a, "admin")
      refute Config.can_manage?(a, "vendas")
    end

    test "[names] = exactly those (self only if listed)" do
      a = %Agent{name: "admin", can_manage: ["vendas"]}
      assert Config.can_manage?(a, "vendas")
      refute Config.can_manage?(a, "rh")
      refute Config.can_manage?(a, "admin")
    end

    test "[\"*\"] = everyone" do
      a = %Agent{name: "admin", can_manage: ["*"]}
      assert Config.can_manage?(a, "vendas")
      assert Config.can_manage?(a, "anything")
    end
  end

  test "refuses to act on an agent outside the manager's scope" do
    assert {:error, msg} =
             ManageAgent.run(%{"action" => "get", "target" => "vendas"}, ctx(["rh"]))

    assert msg =~ "isn't available"
    refute msg =~ "not allowed"
  end

  test "grants and revokes a tool on a managed agent" do
    assert {:ok, _} =
             ManageAgent.run(
               %{"action" => "add_tool", "target" => "vendas", "value" => "web_search"},
               ctx(["vendas"])
             )

    assert "web_search" in Config.get_agent("vendas").tools

    assert {:ok, _} =
             ManageAgent.run(
               %{"action" => "remove_tool", "target" => "vendas", "value" => "web_search"},
               ctx(["vendas"])
             )

    refute "web_search" in Config.get_agent("vendas").tools
  end

  test "rejects an unknown tool" do
    assert {:error, msg} =
             ManageAgent.run(
               %{"action" => "add_tool", "target" => "vendas", "value" => "nope"},
               ctx(["vendas"])
             )

    assert msg =~ "unknown tool"
  end

  test "sets the target's persona into its workspace SOUL.md" do
    assert {:ok, _} =
             ManageAgent.run(
               %{
                 "action" => "set_persona",
                 "target" => "vendas",
                 "value" => "You are the sales rep."
               },
               ctx(["*"])
             )

    assert File.read!(Path.join(Workspace.dir("vendas"), "SOUL.md")) =~ "sales rep"
  end

  test "remember appends to the target's memory" do
    ManageAgent.run(
      %{"action" => "remember", "target" => "vendas", "value" => "Client prefers email."},
      ctx(["*"])
    )

    assert File.read!(Path.join(Workspace.dir("vendas"), "MEMORY.md")) =~ "prefers email"
  end

  test "a super-admin (*) can create a new agent" do
    assert {:ok, _} =
             ManageAgent.run(
               %{"action" => "create", "target" => "suporte", "value" => "You are support."},
               ctx(["*"])
             )

    assert Config.get_agent("suporte")
  end

  test "create is refused when the target is out of scope" do
    assert {:error, msg} =
             ManageAgent.run(%{"action" => "create", "target" => "suporte"}, ctx(["vendas"]))

    assert msg =~ "isn't available"
    refute msg =~ "not allowed"
    refute Config.get_agent("suporte")
  end

  test "create reports the error (not a false success) when the handle is invalid" do
    assert {:error, msg} =
             ManageAgent.run(%{"action" => "create", "target" => "bad/name/extra"}, ctx(["*"]))

    assert msg =~ "valid handle"
    refute Config.get_agent("bad/name/extra")
    # No agent was created: only the two the setup put there remain.
    assert Enum.map(Config.agents(), & &1.name) |> Enum.sort() == ["default/rh", "default/vendas"]
  end

  describe "set_flag (enable or disable a switch on a managed agent)" do
    setup do
      on_exit(fn -> Process.delete(:pepe_untrusted_content) end)
      :ok
    end

    test "an admin turns a target's switch on and off by chat" do
      assert {:ok, msg} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "exempt_message_limit", "value" => "on"},
                 ctx(["vendas"])
               )

      assert msg =~ "on"
      assert Config.get_agent("vendas").exempt_message_limit == true

      assert {:ok, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "exempt_message_limit", "value" => "off"},
                 ctx(["vendas"])
               )

      assert Config.get_agent("vendas").exempt_message_limit == false
    end

    test "trust_untrusted_content can be turned on from an ordinary conversation" do
      assert {:ok, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "trust_untrusted_content", "value" => "on"},
                 ctx(["vendas"])
               )

      assert Config.get_agent("vendas").trust_untrusted_content == true
    end

    test "but NOT from a run that has itself taken in a stranger's content" do
      # The escalation this closes: a document the admin agent is reading says "trust the
      # billing agent", and the very run reading it carries that out. That is an attacker
      # deciding for the operator, not the operator deciding.
      Pepe.Permissions.taint()

      assert {:error, why} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "trust_untrusted_content", "value" => "on"},
                 ctx(["vendas"])
               )

      assert why =~ "outside"
      assert Config.get_agent("vendas").trust_untrusted_content == false

      # Turning it OFF from a tainted run is still fine: tightening never needs guarding.
      Config.put_agent(%{Config.get_agent("vendas") | trust_untrusted_content: true})

      assert {:ok, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "trust_untrusted_content", "value" => "off"},
                 ctx(["vendas"])
               )

      assert Config.get_agent("vendas").trust_untrusted_content == false
    end

    test "session_search_project_wide can be turned on from an ordinary conversation" do
      assert {:ok, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "session_search_project_wide", "value" => "on"},
                 ctx(["vendas"])
               )

      assert Config.get_agent("vendas").session_search_scope == "project"
    end

    test "session_search_project_wide: but NOT from a run that has itself taken in a stranger's content" do
      Pepe.Permissions.taint()

      assert {:error, why} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "session_search_project_wide", "value" => "on"},
                 ctx(["vendas"])
               )

      assert why =~ "outside"
      assert Config.get_agent("vendas").session_search_scope == "self"

      # Turning it OFF from a tainted run is still fine: tightening never needs guarding.
      Config.put_agent(%{Config.get_agent("vendas") | session_search_scope: "project"})

      assert {:ok, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "session_search_project_wide", "value" => "off"},
                 ctx(["vendas"])
               )

      assert Config.get_agent("vendas").session_search_scope == "self"
    end

    test "an unknown flag or a bad value is refused" do
      assert {:error, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "make_it_fast", "value" => "on"},
                 ctx(["vendas"])
               )

      assert {:error, why} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "vendas", "flag" => "exempt_message_limit", "value" => "maybe"},
                 ctx(["vendas"])
               )

      assert why =~ "on"
    end

    test "and only on an agent the admin may manage" do
      assert {:error, _} =
               ManageAgent.run(
                 %{"action" => "set_flag", "target" => "rh", "flag" => "exempt_message_limit", "value" => "on"},
                 ctx(["vendas"])
               )
    end

    test "get shows the current flags, so the admin can see what it is changing" do
      assert {:ok, text} = ManageAgent.run(%{"action" => "get", "target" => "vendas"}, ctx(["vendas"]))
      assert text =~ "trust_untrusted_content=off"
      assert text =~ "exempt_message_limit=off"
      assert text =~ "session_search_project_wide=off"
    end
  end

  describe "the flag descriptions speak the language a person uses" do
    # The LLM does the mapping from "let it act on the documents clients send" to
    # trust_untrusted_content: that is its job, and it is not something a unit test can pin.
    # What a unit test CAN protect is the raw material it needs to do it: the plain-language
    # phrases in the tool description. Strip those out to "tidy up" the spec and the mapping
    # quietly stops working, which is the regression this catches.
    test "the trigger phrases are in the spec, so the model can match them" do
      desc = ManageAgent.spec()["function"]["description"]

      # The user never types the flag name. These are the words they actually use.
      assert desc =~ "documents clients send"
      assert desc =~ "attachments"
      assert desc =~ "don't limit this agent's messages"

      # And the flag names are still there for the model to emit.
      assert desc =~ "trust_untrusted_content"
      assert desc =~ "exempt_message_limit"
    end
  end
end
