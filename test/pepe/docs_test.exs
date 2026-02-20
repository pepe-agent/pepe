defmodule Pepe.DocsTest do
  use ExUnit.Case, async: true

  test "lists the bundled docs with titles" do
    docs = Pepe.Docs.list()
    names = Enum.map(docs, &elem(&1, 0))

    assert "configuring-pepe" in names
    assert "mcp" in names
    assert "agents" in names
  end

  test "reads a doc's content" do
    assert {:ok, content} = Pepe.Docs.read("mcp")
    assert content =~ "MCP"
  end

  test "unknown doc returns an error" do
    assert {:error, :not_found} = Pepe.Docs.read("nope")
  end

  test "the docs tool lists and reads" do
    assert {:ok, listing} = Pepe.Tools.Docs.run(%{}, %{})
    assert listing =~ "mcp"

    assert {:ok, content} = Pepe.Tools.Docs.run(%{"name" => "permissions"}, %{})
    assert content =~ "Permissions"
  end
end
