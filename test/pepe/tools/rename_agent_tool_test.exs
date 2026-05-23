defmodule Pepe.Tools.RenameAgentToolTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.RenameAgent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "renaming onto a colliding name is refused and never moves the workspace directory" do
    Config.put_agent(%Agent{name: "mover", system_prompt: "m"})
    Config.put_agent(%Agent{name: "target", system_prompt: "t"})

    # Give each agent a distinct SOUL.md so a bad move would be observable as identity leakage.
    File.mkdir_p!(Workspace.dir("mover"))
    File.mkdir_p!(Workspace.dir("target"))
    File.write!(Path.join(Workspace.dir("mover"), "SOUL.md"), "i am mover")
    File.write!(Path.join(Workspace.dir("target"), "SOUL.md"), "i am target")

    assert {:error, _} = RenameAgent.run(%{"new_name" => "target"}, %{agent: %{name: "mover"}})

    # Both config entries and both workspaces are untouched: the collision fix must hold end to end.
    assert Config.get_agent("mover").system_prompt == "m"
    assert Config.get_agent("target").system_prompt == "t"
    assert File.read!(Path.join(Workspace.dir("mover"), "SOUL.md")) == "i am mover"
    assert File.read!(Path.join(Workspace.dir("target"), "SOUL.md")) == "i am target"
  end

  test "renaming to an invalid name is refused without touching the filesystem" do
    Config.put_agent(%Agent{name: "mover", system_prompt: "m"})
    File.mkdir_p!(Workspace.dir("mover"))
    File.write!(Path.join(Workspace.dir("mover"), "SOUL.md"), "i am mover")

    assert {:error, _} = RenameAgent.run(%{"new_name" => "../../pwn"}, %{agent: %{name: "mover"}})

    assert Config.get_agent("mover").system_prompt == "m"
    assert File.read!(Path.join(Workspace.dir("mover"), "SOUL.md")) == "i am mover"
  end

  test "a clean rename still relabels the agent and moves its workspace" do
    Config.put_agent(%Agent{name: "mover", system_prompt: "m"})
    File.mkdir_p!(Workspace.dir("mover"))
    File.write!(Path.join(Workspace.dir("mover"), "SOUL.md"), "persona")

    assert {:ok, _} = RenameAgent.run(%{"new_name" => "renamed"}, %{agent: %{name: "mover"}})

    assert Config.get_agent("mover") == nil
    assert Config.get_agent("renamed").system_prompt == "m"
    assert File.read!(Path.join(Workspace.dir("renamed"), "SOUL.md")) == "persona"
  end
end
