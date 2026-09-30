defmodule Pepe.Agent.FootprintTest do
  use ExUnit.Case, async: true

  alias Pepe.Agent.Footprint
  alias Pepe.Agent.Workspace

  defp agent(tools) do
    %{name: "footprint-test", system_prompt: "You are a test agent.", tools: tools}
  end

  test "tokens/1 estimates bytes / 4, rounded up" do
    assert Footprint.tokens("") == 0
    assert Footprint.tokens("abcd") == 1
    assert Footprint.tokens("abcde") == 2
  end

  test "measure/1 splits the floor into prompt sections and tool specs, heaviest first" do
    m = Footprint.measure(agent(["bash", "read_file"]))

    assert Enum.map(m.tools, &elem(&1, 0)) |> Enum.sort() == ["bash", "read_file"]
    assert m.tools == Enum.sort_by(m.tools, &elem(&1, 1), :desc)
    assert m.prompt == Enum.sort_by(m.prompt, &elem(&1, 1), :desc)
    assert m.total == m.prompt_total + m.tools_total
    assert m.tools_total > 0
    assert {"persona", _} = List.keyfind(m.prompt, "persona", 0)
  end

  test "an agent with no tools has no tool cost" do
    m = Footprint.measure(agent([]))

    assert m.tools == []
    assert m.tools_total == 0
    assert m.total == m.prompt_total
  end

  test "the sections are exactly what system_prompt/1 sends" do
    a = agent(["bash"])

    joined = a |> Workspace.system_prompt_sections() |> Enum.map_join("\n\n", &elem(&1, 1))

    assert joined == Workspace.system_prompt(a)
  end
end
