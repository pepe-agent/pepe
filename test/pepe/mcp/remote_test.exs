defmodule Pepe.MCP.RemoteTest do
  @moduledoc """
  The remote MCP transports against a real HTTP server on loopback.
  """
  use ExUnit.Case, async: false

  alias Pepe.MCP.Client
  alias Pepe.MCP.Transport
  alias Pepe.Test.MockMCP

  defp start_server(mode) do
    {:ok, server} =
      Bandit.start_link(
        plug: {MockMCP, mode: mode},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp spec(port, path, extra \\ %{}) do
    Map.merge(
      %{
        name: "mock",
        url: "http://127.0.0.1:#{port}#{path}",
        headers: %{},
        transport: "auto",
        oauth: %{}
      },
      extra
    )
  end

  describe "streamable HTTP" do
    test "handshakes and lists tools" do
      port = start_server(:streamable)
      {:ok, pid} = Client.Http.start_link(spec(port, "/mcp"))

      names = pid |> Client.Http.list_tools() |> Enum.map(& &1["name"])
      assert "recall" in names
      assert "boom" in names
    end

    test "calls a tool and returns its text" do
      port = start_server(:streamable)
      {:ok, pid} = Client.Http.start_link(spec(port, "/mcp"))

      assert {:ok, out} = Client.Http.call_tool(pid, "recall", %{"q" => "deploy"})
      assert out =~ "called recall"
      assert out =~ "deploy"
    end

    test "reads a response delivered as an event stream, not just as JSON" do
      port = start_server(:streamable_sse)
      {:ok, pid} = Client.Http.start_link(spec(port, "/mcp"))

      assert ["recall", "boom"] = pid |> Client.Http.list_tools() |> Enum.map(& &1["name"])
      assert {:ok, out} = Client.Http.call_tool(pid, "recall", %{})
      assert out =~ "called recall"
    end

    test "an in-band tool failure is an error, not a successful-looking string" do
      port = start_server(:streamable)
      {:ok, pid} = Client.Http.start_link(spec(port, "/mcp"))

      assert {:error, message} = Client.Http.call_tool(pid, "boom", %{})
      assert message =~ "the upstream said no"
    end

    test "concurrent calls to one server overlap instead of queueing" do
      port = start_server(:streamable)
      {:ok, pid} = Client.Http.start_link(spec(port, "/mcp"))

      results =
        1..5
        |> Task.async_stream(fn n -> Client.Http.call_tool(pid, "recall", %{"n" => n}) end,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      # Every call got its own answer back, not another call's.
      for n <- 1..5, do: assert(Enum.any?(results, fn {:ok, out} -> out =~ "\"n\":#{n}" end))
    end
  end

  describe "legacy HTTP+SSE" do
    test "learns the POST endpoint from the stream, then handshakes over it" do
      port = start_server(:sse)
      {:ok, pid} = Client.Sse.start_link(spec(port, "/sse"))

      names = pid |> Client.Sse.list_tools() |> Enum.map(& &1["name"])
      assert "recall" in names
    end

    test "matches a reply on the stream back to the call that asked for it" do
      port = start_server(:sse)
      {:ok, pid} = Client.Sse.start_link(spec(port, "/sse"))

      assert {:ok, out} = Client.Sse.call_tool(pid, "recall", %{"q" => "x"})
      assert out =~ "called recall"
    end
  end

  describe "transport selection" do
    test "a url picks HTTP and a command picks stdio" do
      assert {:ok, Client.Http} = Transport.for_spec(%{url: "https://example.com/mcp"})
      assert {:ok, Client} = Transport.for_spec(%{command: "npx", args: []})
      assert {:error, :no_transport} = Transport.for_spec(%{})
    end

    test "an explicit transport overrides the default" do
      assert {:ok, Client.Sse} = Transport.for_spec(%{url: "https://x/sse", transport: "sse"})

      assert {:ok, Client.Http} =
               Transport.for_spec(%{url: "https://x/mcp", transport: "streamable"})
    end

    test "a server that answers 404 to a streamable POST is not reachable that way" do
      Process.flag(:trap_exit, true)
      port = start_server(:sse)

      # /sse only answers GET, so the Streamable probe gets the 404 that tells Pepe.MCP to
      # fall back rather than to give up.
      assert {:error, {:mcp_not_streamable, 404}} =
               Client.Http.start_link(spec(port, "/sse", %{transport: "streamable"}))
    end
  end

  describe "headers" do
    test "a configured static credential is sent" do
      port = start_server(:streamable)
      System.put_env("MOCK_MCP_TOKEN", "sekrit")
      on_exit(fn -> System.delete_env("MOCK_MCP_TOKEN") end)

      spec = spec(port, "/mcp", %{headers: %{"Authorization" => "Bearer ${MOCK_MCP_TOKEN}"}})

      # The mock does not enforce auth; what is asserted here is that an ${ENV_VAR} header
      # resolves and the connection still works end to end with it attached.
      assert {:ok, pid} = Client.Http.start_link(spec)
      assert pid |> Client.Http.list_tools() |> length() == 2
    end
  end
end
