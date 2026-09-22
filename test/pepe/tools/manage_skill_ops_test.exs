defmodule Pepe.Tools.ManageSkillOpsTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Skills.Settings
  alias Pepe.Tools.ManageSkill

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skill_tool_ops_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp ctx, do: %{agent: %Agent{name: "boss", tools: ["skill", "manage_skill"]}, session_key: "telegram:1"}

  defp header(name, extra \\ ""), do: "---\nname: #{name}\ndescription: Use when #{name}.\n#{extra}---\n\nSteps.\n"

  defp write(home, name, text), do: File.write!(Path.join([home, "skills", name <> ".md"]), text)

  defp run!(args), do: ManageSkill.run(args, ctx())

  test "status says why a skill is not offered and what an offered one needs", %{home: home} do
    write(home, "elsewhere", header("elsewhere", "platforms: [plan9]\n"))
    write(home, "needs-key", header("needs-key", "required_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n"))
    write(home, "tg-off", header("tg-off"))
    Settings.disable("tg-off", "telegram")

    assert {:ok, out} = run!(%{"action" => "status"})

    assert out =~ "• elsewhere [user] (not offered: for another operating system)"
    assert out =~ "• needs-key [user] (needs PEPE_TEST_SURELY_UNSET_KEY)"
    assert out =~ "• tg-off [user] (not offered: disabled)"
  end

  describe "validate" do
    test "reports the findings for a skill by name", %{home: home} do
      write(home, "no-header", "just text\n")

      assert {:ok, out} = run!(%{"action" => "validate", "name" => "no-header"})
      assert out =~ "not valid"
      assert out =~ "header_missing"
    end

    test "a good skill is valid", %{home: home} do
      dir = Path.join([home, "skills", "good-one"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), header("good-one"))

      assert {:ok, "good-one: valid, nothing to report."} = run!(%{"action" => "validate", "name" => "good-one"})
    end

    test "takes a name only: a path is not a skill it can see" do
      assert {:error, "no skill named /etc/passwd"} = run!(%{"action" => "validate", "name" => "/etc/passwd"})
      assert {:error, _} = run!(%{"action" => "validate"})
    end
  end

  test "preview shows the skill without installing it", %{home: home} do
    src = Path.join(System.tmp_dir!(), "prev_#{System.unique_integer([:positive])}.md")
    File.write!(src, header("previewed"))
    on_exit(fn -> File.rm(src) end)

    assert {:ok, out} = run!(%{"action" => "preview", "name" => "previewed", "source" => src})

    assert out =~ "previewed (community)"
    assert out =~ "security scan: safe"
    assert out =~ "files: previewed.md"
    assert out =~ "Steps."
    refute File.exists?(Path.join([home, "skills", "previewed.md"]))
  end

  test "check reports on installed skills, and on none" do
    assert {:ok, "No skills installed from a marketplace."} = run!(%{"action" => "check"})
    assert {:ok, "• nothing: not installed"} = run!(%{"action" => "check", "name" => "nothing"})
  end

  describe "enable, disable, autoload and config" do
    test "disable and enable, everywhere or on one channel", %{home: home} do
      write(home, "flip", header("flip"))

      assert {:ok, "flip is now disabled on telegram."} = run!(%{"action" => "disable", "name" => "flip", "channel" => "telegram"})
      assert Settings.channel_disabled("telegram") == ["flip"]

      assert {:ok, "flip is now enabled on telegram."} = run!(%{"action" => "enable", "name" => "flip", "channel" => "telegram"})
      assert Settings.channel_disabled("telegram") == []

      assert {:ok, "flip is now disabled everywhere."} = run!(%{"action" => "disable", "name" => "flip"})
      assert Settings.disabled() == ["flip"]
    end

    test "an unknown skill is refused" do
      assert {:error, "no skill named ghost"} = run!(%{"action" => "disable", "name" => "ghost"})
      assert {:error, "enable needs `name`"} = run!(%{"action" => "enable"})
    end

    test "autoload on and off, but never for a skill from a community source", %{home: home} do
      write(home, "always", header("always"))

      assert {:ok, _} = run!(%{"action" => "autoload", "name" => "always", "value" => "on"})
      assert Settings.auto_load() == ["always"]

      assert {:ok, _} = run!(%{"action" => "autoload", "name" => "always", "value" => "off"})
      assert Settings.auto_load() == []

      Pepe.Config.put_installed_skill("always", %{"source" => "https://example.test/x", "trust_level" => "community"})
      assert {:error, msg} = run!(%{"action" => "autoload", "name" => "always", "value" => "on"})
      assert msg =~ "community source"
      assert Settings.auto_load() == []

      assert {:error, _} = run!(%{"action" => "autoload", "name" => "always"})
    end

    test "config reads and sets a value" do
      assert {:ok, ~s(wiki.path = nil)} = run!(%{"action" => "config", "key" => "wiki.path"})
      assert {:ok, "wiki.path = /srv/wiki"} = run!(%{"action" => "config", "key" => "wiki.path", "value" => "/srv/wiki"})
      assert Settings.config_values() == %{"wiki.path" => "/srv/wiki"}
      assert {:error, _} = run!(%{"action" => "config"})
    end
  end

  test "the operator-only decisions are not actions at all" do
    enum = ManageSkill.spec() |> get_in(["function", "parameters", "properties", "action", "enum"])

    for operator_only <- ~w(trust untrust external inline_shell set) do
      refute operator_only in enum
    end
  end
end
