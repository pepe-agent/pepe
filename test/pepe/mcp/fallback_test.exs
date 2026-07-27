defmodule Pepe.MCP.FallbackTest do
  @moduledoc """
  `Pepe.MCP` picking a transport from config, including the retry that makes
  `transport: "auto"` work: the two remote protocols are told apart only by trying one, so a
  server speaking the older pair has to be reached without the operator having to know that.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.MCP
  alias Pepe.Test.MockMCP

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mcp_fb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    server = "remote#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case Registry.lookup(Pepe.MCP.Registry, server) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Pepe.MCP.DynSup, pid)
        _ -> :ok
      end

      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, server: server}
  end

  defp start_server(mode) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {MockMCP, mode: mode},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  test "a streamable server is reached over the streamable transport", %{server: server} do
    port = start_server(:streamable)
    Config.put_mcp_server(server, %{"url" => "http://127.0.0.1:#{port}/mcp"})

    assert {:ok, pid, MCP.Client.Http} = MCP.ensure(server)
    assert is_pid(pid)
    assert {:ok, tools} = MCP.tools(server)
    assert "recall" in Enum.map(tools, & &1["name"])
  end

  test "a legacy-only server is reached anyway, by falling back", %{server: server} do
    port = start_server(:sse)
    # The URL is the SSE one, which answers 404 to the streamable probe. Nothing in the
    # config says so - that is the point.
    Config.put_mcp_server(server, %{"url" => "http://127.0.0.1:#{port}/sse"})

    assert {:ok, _pid, MCP.Client.Sse} = MCP.ensure(server)
    assert {:ok, tools} = MCP.tools(server)
    assert "recall" in Enum.map(tools, & &1["name"])
  end

  test "pinning the transport disables the fallback", %{server: server} do
    port = start_server(:sse)

    Config.put_mcp_server(server, %{
      "url" => "http://127.0.0.1:#{port}/sse",
      "transport" => "streamable"
    })

    assert {:error, {:mcp_not_streamable, 404}} = MCP.ensure(server)
  end

  test "an agent's tool specs come from a remote server too", %{server: server} do
    port = start_server(:streamable)
    Config.put_mcp_server(server, %{"url" => "http://127.0.0.1:#{port}/mcp"})

    specs = MCP.specs_for(["mcp__#{server}__*", "bash"])
    names = Enum.map(specs, &get_in(&1, ["function", "name"]))

    assert "mcp__#{server}__recall" in names
    refute "bash" in names
  end

  test "calling a remote tool by its namespaced name", %{server: server} do
    port = start_server(:streamable)
    Config.put_mcp_server(server, %{"url" => "http://127.0.0.1:#{port}/mcp"})

    assert {:ok, out} = MCP.call("mcp__#{server}__recall", %{"q" => "hello"})
    assert out =~ "called recall"
  end
end
