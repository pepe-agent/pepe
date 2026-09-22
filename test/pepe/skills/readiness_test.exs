defmodule Pepe.Skills.ReadinessTest do
  use ExUnit.Case, async: true

  alias Pepe.Skills.Frontmatter
  alias Pepe.Skills.Readiness
  alias Pepe.Skills.Skill

  defp skill(header) do
    %{meta: meta} = Frontmatter.parse("---\n#{header}\n---\n\nbody\n")
    %Skill{name: "s", entry: "/tmp/s.md", meta: meta, fields: Frontmatter.fields(meta)}
  end

  defp env(vars), do: fn name -> vars[name] end

  test "a skill that declares nothing is ready" do
    assert %{ready?: true, missing_env: [], missing_commands: []} = Readiness.check(skill("name: s"))
    assert Readiness.note(Readiness.check(skill("name: s"))) == nil
  end

  test "an unset or blank required variable is missing, a set one is not" do
    s = skill("name: s\nrequired_environment_variables: [API_KEY, OTHER_KEY]")

    result = Readiness.check(s, env: env(%{"API_KEY" => "secret", "OTHER_KEY" => "  "}), which: fn _ -> "/bin/x" end)

    assert Enum.map(result.missing_env, & &1.name) == ["OTHER_KEY"]
    refute result.ready?
  end

  test "an optional variable never counts as missing" do
    s = skill("name: s\nrequired_environment_variables:\n  - name: NICE_TO_HAVE\n    optional: true")

    assert Readiness.check(s, env: env(%{})).ready?
  end

  test "a missing command is reported, an installed one is not" do
    s = skill("name: s\nrequired_commands: [jq, definitely-not-installed]")

    result = Readiness.check(s, env: env(%{}), which: fn name -> if name == "jq", do: "/usr/bin/jq" end)

    assert result.missing_commands == ["definitely-not-installed"]
  end

  test "note/1 names every gap in one short line" do
    s = skill("name: s\nrequired_environment_variables: [API_KEY]\nrequired_commands: [jq]")
    result = Readiness.check(s, env: env(%{}), which: fn _ -> nil end)

    assert Readiness.note(result) == "needs API_KEY, command jq"
  end

  test "setup_block/1 carries the skill's own help text and tells the agent not to invent a value" do
    header =
      "name: s\nrequired_environment_variables:\n  - name: API_KEY\n    help: Create one at the provider's console\n    required_for: sending"

    result = Readiness.check(skill(header), env: env(%{}))

    block = Readiness.setup_block(result)
    assert block =~ "environment variable API_KEY is not set"
    assert block =~ "needed for sending"
    assert block =~ "Create one at the provider's console"
    assert block =~ "do not invent a value"
    assert Readiness.setup_block(%{ready?: true}) == nil
  end
end
