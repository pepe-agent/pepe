defmodule Mix.Tasks.PepeSkillOpsCliTest do
  use Pepe.CLICase

  defp write_skill(home, name, text) do
    File.mkdir_p!(Path.join(home, "skills"))
    File.write!(Path.join([home, "skills", name <> ".md"]), text)
  end

  defp header(name, extra \\ ""), do: "---\nname: #{name}\ndescription: Use when #{name}.\n#{extra}---\n\nSteps.\n"

  defp source_file(text) do
    path = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.md")
    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "list --all explains why a skill is not offered, and what an offered one still needs", %{home: home} do
    write_skill(home, "elsewhere", header("elsewhere", "platforms: [plan9]\n"))
    write_skill(home, "switched-off", header("switched-off"))
    write_skill(home, "needs-key", header("needs-key", "required_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n"))
    {_, _} = run(["skill", "disable", "switched-off"])

    {out, _err} = run(["skill", "list"])
    assert out =~ "needs-key"
    assert out =~ "needs PEPE_TEST_SURELY_UNSET_KEY"
    refute out =~ "elsewhere"
    assert out =~ "more not offered to an agent"

    {all, _err} = run(["skill", "list", "--all"])
    assert all =~ "elsewhere"
    assert all =~ "for another operating system"
    assert all =~ "switched-off"
    assert all =~ "disabled"
  end

  test "list --source keeps one tier", %{home: home} do
    write_skill(home, "mine", header("mine"))

    {out, _} = run(["skill", "list", "--source", "user"])
    assert out =~ "mine"
    refute out =~ "install-tool"
  end

  describe "validate" do
    test "a valid skill says so", %{home: home} do
      dir = Path.join([home, "skills", "good-one"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), header("good-one"))

      {out, err} = run(["skill", "validate", dir])
      assert out =~ "good-one: valid"
      assert err == ""
    end

    test "an invalid one lists the findings and fails", %{home: home} do
      dir = Path.join([home, "skills", "bad-one"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "no header\n")

      {out, err} = run(["skill", "validate", dir])
      assert out =~ "header_missing"
      assert err =~ "not valid"
    end

    test "a skill can be named, and an unknown target is reported", %{home: home} do
      write_skill(home, "named", header("named"))

      {out, _} = run(["skill", "validate", "named"])
      assert out =~ "named"

      {_out, err} = run(["skill", "validate", "no-such-skill"])
      assert err =~ "is not a skill directory"
    end
  end

  test "preview shows the files, the scan and the opening text, and installs nothing", %{home: home} do
    src = source_file(header("previewed"))

    {out, _} = run(["skill", "preview", "previewed", "--source", src])

    assert out =~ "previewed"
    assert out =~ "security scan: safe"
    assert out =~ "files: previewed.md"
    assert out =~ "Steps."
    assert out =~ "mix pepe skill install previewed --source"
    refute File.exists?(Path.join([home, "skills", "previewed.md"]))
  end

  test "check says up to date, then that a newer version exists" do
    src = source_file(header("moving"))
    {_, _} = run(["skill", "install", "moving", "--source", src])

    {out, _} = run(["skill", "check", "moving"])
    assert out =~ "moving: up to date"

    File.write!(src, header("moving") <> "A new step.\n")
    {out, _} = run(["skill", "check"])
    assert out =~ "a newer version is available"
  end

  test "install reports what the specification check found, without blocking" do
    src = source_file("no header at all\n")

    {out, _} = run(["skill", "install", "plain", "--source", src])

    assert out =~ "installed"
    assert out =~ "specification check"
    assert out =~ "header_missing"
  end

  test "browse says so when there is nothing to browse" do
    {out, _} = run(["skill", "browse"])
    assert out =~ "Nothing to browse"
  end

  describe "settings" do
    test "enable and disable, everywhere or on one channel", %{home: home} do
      write_skill(home, "flip", header("flip"))

      {out, _} = run(["skill", "disable", "flip", "--channel", "telegram"])
      assert out =~ "disabled on telegram"
      assert Pepe.Skills.Settings.channel_disabled("telegram") == ["flip"]

      {out, _} = run(["skill", "enable", "flip", "--channel", "telegram"])
      assert out =~ "enabled on telegram"
      assert Pepe.Skills.Settings.channel_disabled("telegram") == []

      {_, err} = run(["skill", "disable", "no-such-skill"])
      assert err =~ "no skill named no-such-skill"
    end

    test "trust, trusted and untrust a repository", %{home: home} do
      repo = Path.join(home, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))

      {out, _} = run(["skill", "trust", repo])
      assert out =~ "trusted #{repo}"

      {out, _} = run(["skill", "trusted"])
      assert out =~ repo

      {out, _} = run(["skill", "untrust", repo])
      assert out =~ "no longer trusting"
      {out, _} = run(["skill", "trusted"])
      assert out =~ "No repository is trusted"
    end

    test "external directories and auto-load", %{home: home} do
      ext = Path.join(home, "shared-skills")
      File.mkdir_p!(ext)

      {out, _} = run(["skill", "external", "add", ext])
      assert out =~ "reading skills in place"
      {out, _} = run(["skill", "external", "list"])
      assert out =~ ext
      {_, _} = run(["skill", "external", "remove", ext])
      {out, _} = run(["skill", "external", "list"])
      assert out =~ "No external skill directories"

      write_skill(home, "always", header("always"))
      {_, _} = run(["skill", "autoload", "add", "always"])
      {out, _} = run(["skill", "autoload", "list"])
      assert out =~ "always"
      {_, _} = run(["skill", "autoload", "remove", "always"])
      {out, _} = run(["skill", "autoload", "list"])
      assert out =~ "No skill is auto-loaded"
    end

    test "the two switches, with a word about inline shell" do
      {out, _} = run(["skill", "set", "inline-shell", "on"])
      assert out =~ "inline-shell is on"
      assert out =~ "permission gate"
      assert Pepe.Skills.Settings.inline_shell?()

      {_, _} = run(["skill", "set", "template-vars", "off"])
      refute Pepe.Skills.Settings.template_vars?()

      {_, err} = run(["skill", "set", "nonsense", "on"])
      assert err =~ "usage"
    end

    test "config lists what skills declare and stores a value", %{home: home} do
      write_skill(home, "wiki", header("wiki", "config:\n  - key: wiki.path\n    description: Where it lives\n    default: ~/wiki\n"))

      {out, _} = run(["skill", "config"])
      assert out =~ "wiki.path = ~/wiki"
      assert out =~ "wiki: Where it lives"

      {out, _} = run(["skill", "config", "wiki.path", "/srv/wiki"])
      assert out =~ "wiki.path = /srv/wiki"

      {out, _} = run(["skill", "config", "wiki.path"])
      assert out =~ "wiki.path = /srv/wiki"

      {out, _} = run(["skill", "config", "other.key", "x"])
      assert out =~ "no skill declares other.key yet"
    end
  end

  describe "pack and snapshot" do
    test "pack builds the archive and prints the tap entry; an invalid skill is refused", %{home: home} do
      dir = Path.join(home, "work/packed-one")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), header("packed-one"))
      out_file = Path.join(home, "packed.tar.gz")

      {out, _} = run(["skill", "pack", dir, "--out", out_file])
      assert out =~ "packed packed-one"
      assert out =~ "sha256"
      assert out =~ "skills_registry.json"
      assert File.regular?(out_file)

      File.write!(Path.join(dir, "SKILL.md"), "no header\n")
      {out, err} = run(["skill", "pack", dir, "--out", Path.join(home, "again.tar.gz")])
      assert out =~ "header_missing"
      assert err =~ "not packed"
    end

    test "snapshot export and restore", %{home: home} do
      src = source_file(header("snapped"))
      {_, _} = run(["skill", "install", "snapped", "--source", src])
      snap = Path.join(home, "skills.json")

      {out, _} = run(["skill", "snapshot", "export", snap])
      assert out =~ "wrote 1 skill(s)"

      {out, _} = run(["skill", "snapshot", "restore", snap])
      assert out =~ "already installed from the same source"

      {_, err} = run(["skill", "snapshot", "restore", Path.join(home, "missing.json")])
      assert err =~ "couldn't read"
    end
  end

  test "overrides, diff and reset for a built-in that a copy shadows", %{home: home} do
    {out, _} = run(["skill", "overrides"])
    assert out =~ "No built-in skill is overridden"

    {:ok, shipped} = Pepe.Skills.read("install-tool")
    write_skill(home, "install-tool", shipped <> "\nMy step.\n")

    {out, _} = run(["skill", "overrides"])
    assert out =~ "install-tool"
    assert out =~ "differs from the built-in"

    {out, _} = run(["skill", "diff", "install-tool"])
    assert out =~ "+ My step."

    {out, _} = run(["skill", "reset", "install-tool"])
    assert out =~ "the built-in version serves again"

    {_, err} = run(["skill", "reset", "install-tool"])
    assert err =~ "is not a built-in skill that a copy of yours overrides"
  end
end
