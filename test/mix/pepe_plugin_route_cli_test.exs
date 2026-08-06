defmodule Mix.Tasks.PepePluginRouteCliTest do
  @moduledoc """
  `mix pepe plugin route enable|disable|list` gates a plugin's own HTTP route
  (`Pepe.PluginRoute`) behind an explicit, second opt-in beyond installing the plugin.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_routecli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "route list reports nothing when no plugin claims a route" do
    assert pepe(["plugin", "route", "list"]) =~ "No installed plugin claims an HTTP route"
  end

  test "route list shows a claimed-but-disabled route", %{home: home} do
    write_route_plugin(home, "cli_route")
    assert pepe(["plugin", "route", "list"]) =~ "disabled"
  end

  test "route enable turns it on; list and Config agree", %{home: home} do
    write_route_plugin(home, "cli_route")

    assert pepe(["plugin", "route", "enable", "cli_route"]) =~ "enabled"
    assert Config.http_route_plugins() == ["cli_route"]
    assert pepe(["plugin", "route", "list"]) =~ "enabled"
  end

  test "route disable turns it back off", %{home: home} do
    write_route_plugin(home, "cli_route")
    Config.enable_http_route_plugin("cli_route")

    assert pepe(["plugin", "route", "disable", "cli_route"]) =~ "disabled"
    assert Config.http_route_plugins() == []
  end

  defp write_route_plugin(home, name) do
    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule PepePluginRouteCliTest.#{Macro.camelize(name)} do
      @behaviour Pepe.PluginRoute
      def route_prefix, do: "#{name}"
      def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, "ok")
    end
    """)
  end
end
