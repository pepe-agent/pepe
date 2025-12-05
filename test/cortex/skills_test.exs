defmodule Cortex.SkillsTest do
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "built-in skills are listed with a summary and readable" do
    names = Cortex.Skills.list() |> Enum.map(&elem(&1, 0))
    assert "install-tool" in names

    assert {:ok, content} = Cortex.Skills.read("install-tool")
    assert content =~ "plugins/"
    assert content =~ "Cortex.Tools.Tool"
  end

  test "the skill tool returns the skill's content" do
    assert {:ok, content} = Cortex.Tools.Skill.run(%{"name" => "install-tool"}, %{})
    assert content =~ "enable_tool"
    assert {:error, _} = Cortex.Tools.Skill.run(%{"name" => "nope"}, %{})
  end

  test "a user skill overrides a built-in of the same name", %{home: home} do
    File.write!(Path.join([home, "skills", "install-tool.md"]), "custom override\n")
    assert {:ok, "custom override\n"} = Cortex.Skills.read("install-tool")
  end
end
