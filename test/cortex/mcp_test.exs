defmodule Cortex.MCPTest do
  use ExUnit.Case, async: false

  alias Cortex.Config
  alias Cortex.MCP

  @mock Path.expand("../support/mock_mcp_server.exs", __DIR__)

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_mcp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    # A unique server name per test so cached clients don't leak across tests.
    server = "mock#{System.unique_integer([:positive])}"
    Config.put_mcp_server(server, %{"command" => "elixir", "args" => [@mock]})

    on_exit(fn ->
      case Registry.lookup(Cortex.MCP.Registry, server) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Cortex.MCP.DynSup, pid)
        _ -> :ok
      end

      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, server: server}
  end

  test "mcp_tool? recognizes namespaced names" do
    assert MCP.mcp_tool?("mcp__sentry__find_organizations")
    refute MCP.mcp_tool?("bash")
  end

  test "starts a server on demand and lists its tools", %{server: server} do
    assert {:ok, tools} = MCP.tools(server)
    names = Enum.map(tools, & &1["name"])
    assert "find_organizations" in names
    assert "update_issue" in names
  end

  test "specs_for expands an exact tool and a wildcard", %{server: server} do
    one = MCP.specs_for(["mcp__#{server}__find_organizations"])
    assert [%{"function" => %{"name" => name}}] = one
    assert name == "mcp__#{server}__find_organizations"

    all = MCP.specs_for(["mcp__#{server}__*"])
    assert length(all) == 2
  end

  test "read-only scoping: only listed tools get specs (mutating one excluded)", %{server: server} do
    specs = MCP.specs_for(["mcp__#{server}__find_organizations"])
    names = Enum.map(specs, &get_in(&1, ["function", "name"]))
    refute "mcp__#{server}__update_issue" in names
  end

  test "Tools.execute routes an mcp call to the server", %{server: server} do
    call = %{"function" => %{"name" => "mcp__#{server}__find_organizations", "arguments" => "{}"}}
    out = Cortex.Tools.execute(call, %{})
    assert out =~ "called find_organizations"
  end
end
