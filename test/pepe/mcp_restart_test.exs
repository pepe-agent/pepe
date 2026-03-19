defmodule Pepe.MCPRestartTest do
  use ExUnit.Case, async: false

  test "restart is a safe no-op when no client is running for that server" do
    {:ok, _} = Application.ensure_all_started(:pepe)
    assert Pepe.MCP.restart("no-such-server") == :ok
  end
end
