defmodule Pepe.PluginRouteTest do
  @moduledoc """
  `Pepe.PluginRoute` resolves a plugin's own HTTP route only when exactly one installed
  plugin claims a given `route_prefix/0` AND it's been explicitly enabled - see
  `status/0`'s `collision?` for why two plugins claiming the same prefix must never
  silently resolve to whichever one happens to load first.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.PluginRoute

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_plugin_route_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "with nothing installed, status/0 is empty and occupant/1 is nil" do
    assert PluginRoute.status() == []
    assert PluginRoute.occupant("anything") == nil
  end

  test "a single claimant is listed and resolves once enabled", %{home: home} do
    write_route_plugin(home, "PepePluginRouteTest.Solo", "solo")

    assert [%{prefix: "solo", enabled?: false, collision?: false}] = PluginRoute.status()
    assert PluginRoute.occupant("solo") == nil

    Config.enable_http_route_plugin("solo")
    assert [%{prefix: "solo", enabled?: true, collision?: false, module: PepePluginRouteTest.Solo}] = PluginRoute.status()
    assert PluginRoute.occupant("solo") == PepePluginRouteTest.Solo
  end

  test "two plugins claiming the same prefix collide - neither resolves, even if enabled", %{home: home} do
    write_route_plugin(home, "PepePluginRouteTest.First", "shared", file: "first")
    write_route_plugin(home, "PepePluginRouteTest.Second", "shared", file: "second")
    Config.enable_http_route_plugin("shared")

    assert [%{prefix: "shared", enabled?: true, collision?: true, module: nil}] = PluginRoute.status()
    assert PluginRoute.occupant("shared") == nil
  end

  test "a later-installed plugin cannot silently take over an already-enabled, single-claimant route", %{home: home} do
    write_route_plugin(home, "PepePluginRouteTest.Trusted", "oauth_callback", file: "trusted")
    Config.enable_http_route_plugin("oauth_callback")
    assert PluginRoute.occupant("oauth_callback") == PepePluginRouteTest.Trusted

    # A second, unrelated plugin later claims the SAME prefix (route_prefix/0 is just a
    # string any plugin can pick) - it must never start receiving the trusted route's
    # traffic just by existing.
    write_route_plugin(home, "PepePluginRouteTest.Hijacker", "oauth_callback", file: "hijacker")
    assert PluginRoute.occupant("oauth_callback") == nil
  end

  defp write_route_plugin(home, module, prefix, opts \\ []) do
    file = Keyword.get(opts, :file, prefix)

    File.write!(Path.join([home, "plugins", "#{file}.exs"]), """
    defmodule #{module} do
      @behaviour Pepe.PluginRoute
      def route_prefix, do: "#{prefix}"
      def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, "ok")
    end
    """)
  end
end
