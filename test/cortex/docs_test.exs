defmodule Cortex.DocsTest do
  use ExUnit.Case, async: true

  test "lists the bundled docs with titles" do
    docs = Cortex.Docs.list()
    names = Enum.map(docs, &elem(&1, 0))

    assert "configuring-cortex" in names
    assert "mcp" in names
    assert "agents" in names
  end

  test "reads a doc's content" do
    assert {:ok, content} = Cortex.Docs.read("mcp")
    assert content =~ "MCP"
  end

  test "unknown doc returns an error" do
    assert {:error, :not_found} = Cortex.Docs.read("nope")
  end

  test "the docs tool lists and reads" do
    assert {:ok, listing} = Cortex.Tools.Docs.run(%{}, %{})
    assert listing =~ "mcp"

    assert {:ok, content} = Cortex.Tools.Docs.run(%{"name" => "permissions"}, %{})
    assert content =~ "Permissions"
  end
end
