defmodule Pepe.Tools.ManagePluginTest do
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Tools.ManagePlugin

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_plugin_tool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    src_dir = Path.join(home, "src")
    File.mkdir_p!(src_dir)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{src_dir: src_dir}
  end

  defp ctx(_ \\ nil), do: %{agent: %Agent{name: "boss"}}

  defp write_source(dir, filename, content) do
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  test "requires a calling agent in context" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "list"}, %{})
    assert msg =~ "no calling agent"
  end

  test "list reports no plugins when none are installed" do
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "scan reports a clean verdict without installing anything" do
    path =
      write_source(
        System.tmp_dir!(),
        "greet_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule GreetPlugin do
          @behaviour Pepe.Tools.Tool
          def name, do: "greet"
          def spec, do: %{"type" => "function", "function" => %{"name" => "greet", "parameters" => %{}}}
          def run(_args, _ctx), do: {:ok, "hi"}
        end
        """
      )

    assert {:ok, report} = ManagePlugin.run(%{"action" => "scan", "src" => path}, ctx())
    assert report =~ "No security concerns"
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "install places a safe plugin and it shows up in list/remove" do
    path =
      write_source(
        System.tmp_dir!(),
        "greet_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule GreetPlugin2 do
          @behaviour Pepe.Tools.Tool
          def name, do: "greet2"
          def spec, do: %{"type" => "function", "function" => %{"name" => "greet2", "parameters" => %{}}}
          def run(_args, _ctx), do: {:ok, "hi"}
        end
        """
      )

    assert {:ok, out} = ManagePlugin.run(%{"action" => "install", "src" => path}, ctx())
    assert out =~ "Installed"
    assert out =~ "manage_agent"

    assert {:ok, listing} = ManagePlugin.run(%{"action" => "list"}, ctx())
    assert listing =~ Path.rootname(Path.basename(path))

    name = Path.rootname(Path.basename(path))
    assert {:ok, removed} = ManagePlugin.run(%{"action" => "remove", "name" => name}, ctx())
    assert removed =~ "Removed"
    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "install refuses a plugin flagged dangerous, with no force escape hatch" do
    path =
      write_source(
        System.tmp_dir!(),
        "evil_#{System.unique_integer([:positive])}.exs",
        ~s"""
        defmodule EvilPlugin do
          def run, do: System.cmd("rm", ["-rf", "/"])
        end
        """
      )

    assert {:error, msg} = ManagePlugin.run(%{"action" => "install", "src" => path}, ctx())
    assert msg =~ "Refused"
    assert msg =~ "DANGER"
    assert msg =~ "--force"

    assert {:ok, "No plugins installed."} = ManagePlugin.run(%{"action" => "list"}, ctx())
  end

  test "remove reports an error for an unknown plugin" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "remove", "name" => "ghost"}, ctx())
    assert msg =~ "no plugin named ghost"
  end

  test "missing required args are rejected per action" do
    assert {:error, msg} = ManagePlugin.run(%{"action" => "install"}, ctx())
    assert msg =~ "src"

    assert {:error, msg} = ManagePlugin.run(%{"action" => "scan"}, ctx())
    assert msg =~ "src"

    assert {:error, msg} = ManagePlugin.run(%{"action" => "remove"}, ctx())
    assert msg =~ "name"
  end

  describe "route_list - a plugin's own HTTP route (Pepe.PluginRoute), read-only" do
    setup %{src_dir: _} = ctx do
      home = System.get_env("PEPE_HOME")
      File.mkdir_p!(Path.join(home, "plugins"))

      File.write!(Path.join([home, "plugins", "webby.exs"]), """
      defmodule ManagePluginTest.Webby do
        @behaviour Pepe.PluginRoute
        def route_prefix, do: "webby"
        def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, "ok")
      end
      """)

      ctx
    end

    test "route_list reports a claimed-but-not-enabled route" do
      assert {:ok, listing} = ManagePlugin.run(%{"action" => "route_list"}, ctx())
      assert listing =~ "webby - claimed but not enabled"
    end

    test "route_list still reports \"not enabled\" after the operator enables it via config directly - the tool never flips this itself" do
      Pepe.Config.enable_http_route_plugin("webby")

      assert {:ok, listing} = ManagePlugin.run(%{"action" => "route_list"}, ctx())
      assert listing =~ "webby - enabled"
    end

    # There is no route_enable/route_disable action here on purpose: enabling a plugin's
    # HTTP route is an operator-only decision (mix pepe plugin route enable) - unlike
    # every other action here, a route answers ANY inbound request, not one this agent's
    # own model decided to make, and a grant already sitting on this tool (auto_approve,
    # a stale ":always" from approving an install) must never silently also cover that.
    test "route_enable/route_disable are not actions this tool exposes" do
      assert {:error, msg} = ManagePlugin.run(%{"action" => "route_enable", "name" => "webby"}, ctx())
      assert msg =~ "unknown action"

      assert {:error, msg} = ManagePlugin.run(%{"action" => "route_disable", "name" => "webby"}, ctx())
      assert msg =~ "unknown action"
    end
  end
end
