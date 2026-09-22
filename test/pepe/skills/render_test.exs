defmodule Pepe.Skills.RenderTest do
  use ExUnit.Case, async: false

  alias Pepe.Skills.Render
  alias Pepe.Skills.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skill_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp write(home, name, text) do
    File.write!(Path.join([home, "skills", name <> ".md"]), text)
    {:ok, skill} = Pepe.Skills.Catalog.find(name)
    skill
  end

  defp fetch(name, ctx \\ %{}) do
    {:ok, skill, content} = Pepe.Skills.fetch(name)
    Render.render(skill, content, ctx)
  end

  describe "template variables" do
    test "the skill's directory, the skills directory and the session are substituted", %{home: home} do
      dir = Path.join([home, "skills", "pkg"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "Run ${PEPE_SKILL_DIR}/scripts/go.sh in ${PEPE_SESSION_ID} from ${PEPE_SKILLS_DIR}.\n")

      out = fetch("pkg", %{session_key: "acp:abc"})

      assert out =~ "Run #{dir}/scripts/go.sh in acp:abc from #{Path.join(home, "skills")}."
    end

    test "an unknown variable, and a known one with no value, are left exactly as written", %{home: home} do
      write(home, "vars", "Keep ${HOME} and ${PEPE_UNKNOWN} and ${PEPE_SESSION_ID}.\n")

      assert fetch("vars") == "Keep ${HOME} and ${PEPE_UNKNOWN} and ${PEPE_SESSION_ID}.\n"
    end

    test "turning the setting off leaves the text alone", %{home: home} do
      write(home, "off", "At ${PEPE_SKILL_DIR}.\n")
      Settings.set_flag("template_vars", false)

      assert fetch("off") == "At ${PEPE_SKILL_DIR}.\n"
    end
  end

  describe "configuration" do
    @declared "---\nname: wiki\ndescription: Use when filing notes.\nconfig:\n  - key: wiki.path\n    description: Where the wiki lives\n    default: ~/wiki\n  - key: wiki.owner\n    description: Whose wiki it is\n---\n\nbody\n"

    test "declared settings are listed with the operator's value, else the default, else not set", %{home: home} do
      write(home, "wiki", @declared)
      Settings.put_config("wiki.owner", "Ana")

      out = fetch("wiki")

      assert out =~ "## Skill configuration (set by the operator)"
      assert out =~ "- wiki.path: ~/wiki (Where the wiki lives)"
      assert out =~ "- wiki.owner: Ana (Whose wiki it is)"
    end

    test "a setting with neither value nor default says so", %{home: home} do
      write(
        home,
        "bare",
        "---\nname: bare\ndescription: Use when needed.\nconfig:\n  - key: a.b\n    description: Something\n---\n\nbody\n"
      )

      assert fetch("bare") =~ "- a.b: not set (Something)"
    end

    test "a skill that declares no settings gets no block", %{home: home} do
      write(home, "plain", "Use when plain.\n")

      refute fetch("plain") =~ "Skill configuration"
    end
  end

  test "a skill whose declared variable is missing opens with a setup note", %{home: home} do
    write(
      home,
      "needs",
      "---\nname: needs\ndescription: Use when calling.\nrequired_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n---\n\nbody\n"
    )

    out = fetch("needs")

    assert String.starts_with?(out, "<system-reminder>")
    assert out =~ "environment variable PEPE_TEST_SURELY_UNSET_KEY is not set"
    assert out =~ "body"
  end

  describe "inline shell" do
    @risky "Before: !`echo curl` after.\n"

    defp bash_agent, do: %{name: "zak", tools: ["bash", "skill"]}

    test "is off by default: the snippet stays as written", %{home: home} do
      write(home, "shell", @risky)

      assert fetch("shell", %{agent: bash_agent()}) == @risky
    end

    test "when on, an approved command's output replaces the snippet", %{home: home} do
      write(home, "shell", @risky)
      Settings.set_flag("inline_shell", true)

      ctx = %{agent: bash_agent(), authorize: fn _name, _args, _ctx -> :once end}

      assert fetch("shell", ctx) == "Before: curl after.\n"
    end

    test "when on, a refused command is replaced by a note and never runs", %{home: home} do
      write(home, "shell", @risky)
      Settings.set_flag("inline_shell", true)

      ctx = %{agent: bash_agent(), authorize: fn _name, _args, _ctx -> :deny end}

      out = fetch("shell", ctx)
      assert out =~ "[inline command not run:"
      refute out =~ "Before: curl"
    end

    test "an agent without bash never runs one", %{home: home} do
      write(home, "shell", @risky)
      Settings.set_flag("inline_shell", true)

      assert fetch("shell", %{agent: %{tools: ["skill"]}}) =~ "[inline command not run: this agent has no bash tool]"
    end

    test "a skill installed from a community source never runs one", %{home: home} do
      write(home, "shell", @risky)
      Settings.set_flag("inline_shell", true)
      Pepe.Config.put_installed_skill("shell", %{"source" => "https://example.test/x", "trust_level" => "community"})

      ctx = %{agent: bash_agent(), authorize: fn _name, _args, _ctx -> :once end}

      assert fetch("shell", ctx) == @risky
    end

    test "only the first few distinct commands run", %{home: home} do
      commands = Enum.map_join(1..12, " ", &"!`echo curl#{&1}`")
      write(home, "many", commands <> "\n")
      Settings.set_flag("inline_shell", true)

      out = fetch("many", %{agent: bash_agent(), authorize: fn _n, _a, _c -> :once end})

      assert out =~ "curl10"
      assert out =~ "[inline command not run: too many in one skill]"
    end
  end

  describe "auto_loaded/1" do
    setup %{home: home} do
      write(home, "always-on", "Always do the thing.\n")
      write(home, "other", "Not loaded.\n")
      Settings.add_auto_load("always-on")
      :ok
    end

    test "returns the listed skills for an agent that can open skills" do
      assert [{"always-on", text}] = Render.auto_loaded(agent: %{tools: ["skill"]})
      assert text =~ "Always do the thing."
    end

    test "returns nothing for an agent without the skill tool" do
      assert Render.auto_loaded(agent: %{tools: ["bash"]}) == []
    end

    test "never carries a skill from a community source into the system prompt" do
      Pepe.Config.put_installed_skill("always-on", %{"source" => "https://example.test/x", "trust_level" => "community"})

      assert Render.auto_loaded(agent: %{tools: ["skill"]}) == []
    end

    test "never runs inline shell, even when it is switched on", %{home: home} do
      write(home, "always-on", "Run !`echo curl`.\n")
      Settings.set_flag("inline_shell", true)

      assert [{"always-on", "Run !`echo curl`.\n"}] = Render.auto_loaded(agent: %{tools: ["skill", "bash"]})
    end

    test "cuts a very long skill and says so", %{home: home} do
      write(home, "always-on", String.duplicate("x", 7_000))

      assert [{"always-on", text}] = Render.auto_loaded(agent: %{tools: ["skill"]})
      assert text =~ "[always-on truncated at 6000 characters]"
    end
  end

  describe "the skills index in the system prompt" do
    test "lists what a skill needs, and keeps auto-loaded skills in full", %{home: home} do
      write(
        home,
        "needs",
        "---\nname: needs\ndescription: Use when calling.\nrequired_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n---\n\nbody\n"
      )

      write(home, "always-on", "Always do the thing.\n")
      Settings.add_auto_load("always-on")

      prompt = Pepe.Agent.Workspace.system_prompt(%{name: "zak", system_prompt: "seed", tools: ["skill"]})

      assert prompt =~ "- needs: Use when calling. (needs PEPE_TEST_SURELY_UNSET_KEY)"
      assert prompt =~ "## Skills kept in context in full"
      assert prompt =~ "### always-on\nAlways do the thing."
    end
  end
end
