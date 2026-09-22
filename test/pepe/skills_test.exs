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

  describe "portable metadata header" do
    test "a header's description is the summary, and the body is the instructions", %{home: home} do
      File.write!(Path.join([home, "skills", "read-pdf.md"]), """
      ---
      name: read-pdf
      description: Extracts text and tables from PDF files. Use when the user sends a PDF or mentions forms.
      license: Apache-2.0
      metadata:
        author: example-org
        version: "1.0"
      ---

      Run `scripts/extract.py` with the path.
      """)

      assert {"read-pdf", "Extracts text and tables from PDF files. Use when the user sends a PDF or mentions forms."} in Pepe.Skills.list()

      assert {:ok, content} = Pepe.Skills.read("read-pdf")
      assert content =~ "Run `scripts/extract.py` with the path."
    end

    test "a header on a package's SKILL.md works the same as on a loose file", %{home: home} do
      pkg = Path.join([home, "skills", "greet"])
      File.mkdir_p!(pkg)

      File.write!(Path.join(pkg, "SKILL.md"), """
      ---
      name: greet
      description: Greets a person. Use when the user says hello.
      ---

      Say hi.
      """)

      assert {"greet", "Greets a person. Use when the user says hello."} in Pepe.Skills.list()
    end

    test "a folded or multi-line description is flattened to one line for the index", %{home: home} do
      File.write!(Path.join([home, "skills", "folded.md"]), """
      ---
      name: folded
      description: >-
        Does a thing.
        Use when the thing comes up.
      ---

      Body.
      """)

      assert {"folded", "Does a thing. Use when the thing comes up."} in Pepe.Skills.list()
    end

    test "a doc with no description in its header still summarizes from the body", %{home: home} do
      File.write!(Path.join([home, "skills", "bare.md"]), "---\nname: bare\n---\n\nUse when bare.\n")

      assert {"bare", "Use when bare."} in Pepe.Skills.list()
    end

    test "a doc that merely opens with a horizontal rule is untouched", %{home: home} do
      content = "---\n\nUse when ruled.\n"
      File.write!(Path.join([home, "skills", "ruled.md"]), content)

      assert {"ruled", "Use when ruled."} in Pepe.Skills.list()
      assert Pepe.Skills.read("ruled") == {:ok, content}
      assert Pepe.Skills.header(content) == {%{}, content}
    end

    test "a malformed header degrades to no header instead of raising", %{home: home} do
      content = "---\nname: [unterminated\n---\n\nUse when broken.\n"
      File.write!(Path.join([home, "skills", "broken.md"]), content)

      assert {%{}, ^content} = Pepe.Skills.header(content)
      assert {"broken", _summary} = Enum.find(Pepe.Skills.list(), &(elem(&1, 0) == "broken"))
    end

    test "header/1 returns the metadata map and the body below it" do
      assert {%{"name" => "x", "description" => "d"}, "Body.\n"} =
               Pepe.Skills.header("---\nname: x\ndescription: d\n---\nBody.\n")
    end

    test "header/1 recovers a plain description value that happens to contain a colon, same as Frontmatter.parse/1" do
      content = "---\nname: x\ndescription: Use when: the user sends a PDF\n---\nBody.\n"

      assert {meta, "Body.\n"} = Pepe.Skills.header(content)
      assert meta["name"] == "x"
      assert meta["description"] == "Use when: the user sends a PDF"
    end
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
