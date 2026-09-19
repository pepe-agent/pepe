defmodule Pepe.ACP.McpDescriptorTest do
  @moduledoc """
  What an editor's `mcpServers` list is allowed to turn into: the three descriptor shapes,
  every way one can be malformed, and the guarantees on the specs that come out (literal
  values, no stored-credential lookup, a namespace no configured server can be mistaken for).
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Mcp.Descriptor
  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_acp_mcp_desc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp stdio(overrides \\ %{}),
    do: Map.merge(%{"name" => "files", "command" => "npx", "args" => ["-y", "srv"], "env" => [%{"name" => "K", "value" => "v"}]}, overrides)

  defp http(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "type" => "http",
          "name" => "docs",
          "url" => "https://mcp.example.com/mcp",
          "headers" => [%{"name" => "Authorization", "value" => "Bearer t"}]
        },
        overrides
      )

  defp reason_for(descriptor) do
    assert {[], [{_name, reason}]} = Descriptor.normalize([descriptor])
    reason
  end

  describe "accepted shapes" do
    test "a stdio server becomes a literal spec with no name, starting in the editor's cwd" do
      assert {[server], []} = Descriptor.normalize([stdio()], cwd: "/work/project")

      assert server.name == "files"
      assert server.ns == "editor_files"
      assert server.transport == :stdio

      assert server.spec == %{
               name: nil,
               command: "npx",
               args: ["-y", "srv"],
               env: %{"K" => "v"},
               cwd: "/work/project",
               literal: true
             }
    end

    test "an http server tries Streamable HTTP first and may fall back; an sse one does not" do
      assert {[h], []} = Descriptor.normalize([http()])
      assert h.transport == :http
      assert h.spec.transport == "auto"
      assert h.spec.headers == %{"Authorization" => "Bearer t"}
      assert h.spec.name == nil
      assert h.spec.literal == true

      assert {[s], []} = Descriptor.normalize([http(%{"type" => "sse", "name" => "old"})])
      assert s.transport == :sse
      assert s.spec.transport == "sse"
    end

    test "the type may be left off: a url means http, a command means stdio" do
      assert {[a, b], []} =
               Descriptor.normalize([Map.delete(http(), "type"), Map.delete(stdio(), "args")])

      assert {a.transport, b.transport} == {:http, :stdio}
      assert b.spec.args == []
    end

    test "env and headers may also arrive as a plain map" do
      assert {[s], []} = Descriptor.normalize([stdio(%{"env" => %{"A" => "1"}})])
      assert s.spec.env == %{"A" => "1"}
    end

    test "a variable's value may hold a newline, a header's may not" do
      assert {[_], []} = Descriptor.normalize([stdio(%{"env" => [%{"name" => "PEM", "value" => "a\nb"}]})])

      assert reason_for(http(%{"headers" => [%{"name" => "X", "value" => "a\r\nInjected: 1"}]})) =~ "invalid value"
    end
  end

  describe "rejections" do
    test "each malformed server is refused with a reason a person can act on, and never raises" do
      assert reason_for("not a map") =~ "not an MCP server"
      assert reason_for(%{"command" => "x"}) =~ "no name"
      assert reason_for(%{"name" => "  "}) =~ "no name"
      assert reason_for(%{"name" => "x"}) =~ "neither a `command` nor a `url`"
      assert reason_for(%{"name" => "x", "type" => "carrier-pigeon"}) =~ "unsupported transport"
      assert reason_for(stdio(%{"command" => ""})) =~ "empty"
      assert reason_for(stdio(%{"command" => "./server"})) =~ "absolute path or a bare name"
      assert reason_for(stdio(%{"args" => [1, 2]})) =~ "list of strings"
      assert reason_for(stdio(%{"env" => [%{"name" => "1BAD", "value" => "v"}]})) =~ "invalid environment variable name"
      assert reason_for(http(%{"url" => "file:///etc/passwd"})) =~ "http or https"
      assert reason_for(http(%{"url" => nil})) =~ "no `url`"
      assert reason_for(http(%{"headers" => [%{"name" => "bad header", "value" => "v"}]})) =~ "invalid header name"
    end

    test "an absolute command path and a bare name are both fine" do
      assert {[_, _], []} = Descriptor.normalize([stdio(%{"command" => "/usr/local/bin/srv"}), stdio(%{"name" => "b"})])
    end

    test "no more than eight servers per session; the rest are named as refused" do
      many = for n <- 1..10, do: stdio(%{"name" => "s#{n}"})

      assert {accepted, rejected} = Descriptor.normalize(many)
      assert length(accepted) == Descriptor.max_servers()
      assert Enum.map(rejected, &elem(&1, 0)) == ["s9", "s10"]
      assert Enum.all?(rejected, fn {_name, reason} -> reason =~ "too many servers" end)
    end

    test "one bad server does not cost the good ones" do
      assert {[good], [{"broken", _reason}]} =
               Descriptor.normalize([stdio(%{"name" => "broken", "command" => "./x"}), stdio()])

      assert good.name == "files"
    end
  end

  describe "namespace" do
    test "a name is reduced to a slug that can never contain the `__` a tool name splits on" do
      assert {[a, b, c], []} =
               Descriptor.normalize([
                 stdio(%{"name" => "My Server.v2"}),
                 stdio(%{"name" => "a__b"}),
                 stdio(%{"name" => "!!!"})
               ])

      assert a.ns == "editor_My_Server_v2"
      assert b.ns == "editor_a_b"
      assert c.ns == "editor_server"
      refute Enum.any?([a, b, c], &String.contains?(&1.ns, "__"))
    end

    test "two names that reduce to the same slug are kept apart" do
      assert {[a, b, c], []} =
               Descriptor.normalize([stdio(%{"name" => "x y"}), stdio(%{"name" => "x.y"}), stdio(%{"name" => "x_y"})])

      assert Enum.uniq([a.ns, b.ns, c.ns]) |> length() == 3
    end

    test "a namespace equal to a configured server's name is refused, so an editor cannot speak as it" do
      Config.put_mcp_server("editor_github", %{"command" => "gh-mcp"})

      assert {[], [{"github", reason}]} = Descriptor.normalize([stdio(%{"name" => "github"})])
      assert reason =~ "already taken by a server configured"
    end
  end

  describe "the literal guarantee" do
    test "a value that looks like a reference is kept as text by the spec, and expands only for a configured one" do
      value = "${HOME}"

      descriptor = stdio(%{"env" => [%{"name" => "T", "value" => value}], "args" => [value]})

      assert {[s], []} = Descriptor.normalize([descriptor])
      assert s.spec.literal
      assert Pepe.MCP.Protocol.interp(value, s.spec) == value

      # The same string in an operator's own config is a reference, as documented.
      refute Pepe.MCP.Protocol.interp(value, %{command: "x"}) == value
    end
  end
end
