defmodule Cortex.Agent.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Cortex.Agent.Workspace

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "relative paths resolve into the agent workspace" do
    assert Workspace.resolve("people.md", "zak") == Path.join(Workspace.dir("zak"), "people.md")
  end

  test "shared/ paths resolve into the shared space" do
    assert Workspace.resolve("shared/people.md", "zak") ==
             Path.join(Workspace.shared_dir(), "people.md")
  end

  test "plugins/ and skills/ paths resolve into their global dirs" do
    assert Workspace.resolve("plugins/x.exs", "zak") ==
             Path.join(Workspace.plugins_dir(), "x.exs")

    assert Workspace.resolve("skills/x.md", "zak") == Path.join(Workspace.skills_dir(), "x.md")
  end

  test "absolute paths are left as-is" do
    assert Workspace.resolve("/etc/hosts", "zak") == "/etc/hosts"
  end

  test "resolve_in_ctx uses the bound agent, else cwd" do
    ctx = %{agent: %{name: "zak"}, cwd: "/tmp"}

    assert Workspace.resolve_in_ctx("notes.md", ctx) ==
             Path.join(Workspace.dir("zak"), "notes.md")

    assert Workspace.resolve_in_ctx("notes.md", %{cwd: "/tmp"}) == "/tmp/notes.md"
  end

  test "system_prompt uses SOUL.md when present, else the seed prompt" do
    agent = %{name: "zak", system_prompt: "seed persona"}
    assert Workspace.system_prompt(agent) =~ "seed persona"

    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "SOUL.md"), "You are ZakAI.")

    prompt = Workspace.system_prompt(agent)
    assert prompt =~ "You are ZakAI."
    refute prompt =~ "seed persona"
  end

  test "the rename_agent tool renames the agent in config and moves its workspace" do
    Cortex.Config.put_agent(%Cortex.Config.Agent{name: "teste", system_prompt: "x", tools: []})
    File.mkdir_p!(Workspace.dir("teste"))
    File.write!(Path.join(Workspace.dir("teste"), "SOUL.md"), "soul")

    assert {:ok, _} =
             Cortex.Tools.RenameAgent.run(%{"new_name" => "zak"}, %{agent: %{name: "teste"}})

    assert Cortex.Config.get_agent("teste") == nil
    assert Cortex.Config.get_agent("zak")
    assert File.read!(Path.join(Workspace.dir("zak"), "SOUL.md")) == "soul"
  end

  test "rename moves the agent workspace directory" do
    File.mkdir_p!(Workspace.dir("teste"))
    File.write!(Path.join(Workspace.dir("teste"), "SOUL.md"), "I am.")

    Workspace.rename("teste", "zak")

    refute File.dir?(Workspace.dir("teste"))
    assert File.read!(Path.join(Workspace.dir("zak"), "SOUL.md")) == "I am."
  end

  test "system_prompt lists knowledge files by name (not content) and adds the note" do
    agent = %{name: "zak", system_prompt: "seed"}
    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "USER.md"), "The user is Jho.")
    File.write!(Path.join(Workspace.dir("zak"), "people.md"), "lots of people data")

    prompt = Workspace.system_prompt(agent)

    # listed by name, read on demand — content NOT preloaded
    assert prompt =~ "- USER.md"
    assert prompt =~ "- people.md"
    refute prompt =~ "The user is Jho."
    refute prompt =~ "lots of people data"

    assert prompt =~ "Your workspace"
    assert prompt =~ "shared/"
  end

  test "IDENTITY.md is small enough to stay always-loaded" do
    agent = %{name: "zak", system_prompt: "seed"}
    File.mkdir_p!(Workspace.dir("zak"))
    File.write!(Path.join(Workspace.dir("zak"), "IDENTITY.md"), "name: ZakAI")

    assert Workspace.system_prompt(agent) =~ "name: ZakAI"
  end
end
