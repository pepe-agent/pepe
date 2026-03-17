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
end
