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
end
