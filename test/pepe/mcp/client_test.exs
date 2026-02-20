defmodule Pepe.MCP.ClientTest do
  use ExUnit.Case, async: false

  alias Pepe.MCP.Client

  @mock Path.expand("../../support/mock_mcp_server.exs", __DIR__)

  defp start_mock do
    Client.start_link(%{command: "elixir", args: [@mock]})
  end

  test "handshakes, lists tools, and skips the non-JSON startup banner" do
    {:ok, pid} = start_mock()
    names = Client.list_tools(pid) |> Enum.map(& &1["name"])

    assert "find_organizations" in names
    assert "update_issue" in names
  end

  test "calls a tool and returns its text content" do
    {:ok, pid} = start_mock()
    assert {:ok, out} = Client.call_tool(pid, "find_organizations", %{"limit" => 5})
    assert out =~ "called find_organizations"
    assert out =~ "limit"
  end

  test "fails cleanly when the command doesn't exist" do
    Process.flag(:trap_exit, true)

    assert {:error, _} =
             Client.start_link(%{command: "definitely-not-a-real-binary-xyz", args: []})
  end
end
