defmodule Pepe.Tools.ManageMcpConversationalTest do
  @moduledoc "The MCP surface an agent actually reaches, from a conversation."
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.ManageMcp

  @ctx [agent: "ops"]

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "adds a remote server with headers" do
    assert {:ok, out} =
             ManageMcp.run(
               %{
                 "action" => "add",
                 "name" => "memclaw",
                 "url" => "https://memclaw.net/mcp",
                 "headers" => %{"Authorization" => "Bearer ${MEMCLAW_API_KEY}"}
               },
               @ctx
             )

    assert out =~ "saved"

    assert %{
             "url" => "https://memclaw.net/mcp",
             "headers" => %{"Authorization" => "Bearer ${MEMCLAW_API_KEY}"},
             "transport" => "auto"
           } = Config.mcp_servers()["memclaw"]
  end

  test "the transport can be pinned from a conversation, not just from the CLI" do
    assert {:ok, _} =
             ManageMcp.run(
               %{"action" => "add", "name" => "old", "url" => "https://x/sse", "transport" => "sse"},
               @ctx
             )

    assert Config.mcp_servers()["old"]["transport"] == "sse"
  end

  test "the declared schema covers every field the code reads" do
    props = ManageMcp.spec()["function"]["parameters"]["properties"]
    # A field read by definition/1 but absent here is unreachable: no model can pass what
    # it was never told about.
    for field <- ~w(name url headers transport command args env action) do
      assert Map.has_key?(props, field), "#{field} is read by the tool but not declared"
    end
  end

  test "a server with no url and no command is refused, not half-saved" do
    assert {:error, message} = ManageMcp.run(%{"action" => "add", "name" => "nope"}, @ctx)
    assert message =~ "url"
    assert Config.mcp_servers() == %{}
  end

  test "a raw token in headers is saved and reported, not silently swallowed" do
    assert {:ok, out} =
             ManageMcp.run(
               %{
                 "action" => "add",
                 "name" => "leaky",
                 "url" => "https://x/mcp",
                 "headers" => %{"X-Api-Key" => "sk-live-abcdefghijklmnopqrstuvwxyz0123456789"}
               },
               @ctx
             )

    assert out =~ "saved"
    assert out =~ ~r/revoke|reissue|compromised/i
    assert Config.mcp_servers()["leaky"], "the server is still saved - refusing would not un-leak it"
  end

  test "list reports what credential a remote server has" do
    ManageMcp.run(%{"action" => "add", "name" => "bare", "url" => "https://x/mcp"}, @ctx)
    assert {:ok, out} = ManageMcp.run(%{"action" => "list"}, @ctx)
    assert out =~ "NONE"

    ManageMcp.run(
      %{"action" => "add", "name" => "keyed", "url" => "https://y/mcp", "headers" => %{"Authorization" => "Bearer ${T}"}},
      @ctx
    )

    assert {:ok, out} = ManageMcp.run(%{"action" => "list"}, @ctx)
    assert out =~ "static key"
  end

  test "logout on a server that was never signed in says so instead of failing" do
    ManageMcp.run(%{"action" => "add", "name" => "bare", "url" => "https://x/mcp"}, @ctx)
    assert {:ok, out} = ManageMcp.run(%{"action" => "logout", "name" => "bare"}, @ctx)
    assert out =~ "nothing to forget"
  end

  test "signing in is deliberately not an action an agent can take" do
    actions = ManageMcp.spec()["function"]["parameters"]["properties"]["action"]["enum"]
    refute "login" in actions
    assert "logout" in actions
  end
end
