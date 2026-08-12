defmodule Pepe.SkillsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "built-in skills are listed with a summary and readable" do
    names = Pepe.Skills.list() |> Enum.map(&elem(&1, 0))
    assert "install-tool" in names

    assert {:ok, content} = Pepe.Skills.read("install-tool")
    assert content =~ "plugins/"
    assert content =~ "Pepe.Tools.Tool"
  end

  test "the skill tool returns the skill's content" do
    assert {:ok, content} = Pepe.Tools.Skill.run(%{"name" => "install-tool"}, %{})
    assert content =~ "enable_tool"
    assert {:error, _} = Pepe.Tools.Skill.run(%{"name" => "nope"}, %{})
  end

  test "a user skill overrides a built-in of the same name", %{home: home} do
    File.write!(Path.join([home, "skills", "install-tool.md"]), "custom override\n")
    assert {:ok, "custom override\n"} = Pepe.Skills.read("install-tool")
  end

  test "a package skill (SKILL.md + scripts/) is listed and read like any other", %{home: home} do
    pkg = Path.join([home, "skills", "greet"])
    File.mkdir_p!(Path.join(pkg, "scripts"))
    File.write!(Path.join(pkg, "SKILL.md"), "Use when greeting someone.\n\nRun scripts/hello.py.\n")
    File.write!(Path.join(pkg, "scripts/hello.py"), "print('hi')\n")

    assert {"greet", "Use when greeting someone."} in Pepe.Skills.list()
    assert {:ok, "Use when greeting someone.\n\nRun scripts/hello.py.\n"} = Pepe.Skills.read("greet")
  end

  test "a package skill's bundled script is reachable through the ordinary skills/ workspace path", %{home: home} do
    pkg = Path.join([home, "skills", "greet"])
    File.mkdir_p!(Path.join(pkg, "scripts"))
    File.write!(Path.join(pkg, "SKILL.md"), "Use when greeting someone.\n")
    File.write!(Path.join(pkg, "scripts/hello.py"), "print('hi')\n")

    resolved = Pepe.Agent.Workspace.resolve("skills/greet/scripts/hello.py", "some-agent")
    assert resolved == Path.join(pkg, "scripts/hello.py")
    assert File.read!(resolved) == "print('hi')\n"
  end

  test "a package with no SKILL.md falls back to <dirname>.md, then its first *.md", %{home: home} do
    named = Path.join([home, "skills", "named"])
    File.mkdir_p!(named)
    File.write!(Path.join(named, "named.md"), "Use named.\n")
    assert {:ok, "Use named.\n"} = Pepe.Skills.read("named")

    first = Path.join([home, "skills", "first"])
    File.mkdir_p!(first)
    File.write!(Path.join(first, "whatever.md"), "Use first.\n")
    assert {:ok, "Use first.\n"} = Pepe.Skills.read("first")
  end
end
