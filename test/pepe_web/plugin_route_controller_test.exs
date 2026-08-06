defmodule PepeWeb.PluginRouteControllerTest do
  @moduledoc """
  `/plugin-routes/:plugin/*path` dispatches to whatever plugin claims and is enabled
  for `:plugin` (see `Pepe.PluginRoute`). Claiming a route (exporting the callbacks)
  is not enough on its own - it must also be explicitly enabled, the second gate
  `Pepe.Config.enable_http_route_plugin/1` exists for.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_route_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "404s a prefix no plugin claims" do
    conn = get(build_conn(), "/plugin-routes/does-not-exist/anything")
    assert conn.status == 404
  end

  test "404s a plugin that claims a route but was never enabled", %{home: home} do
    write_route_plugin(
      home,
      "PepeRouteTest.Unenabled",
      "unenabled",
      "def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, \"should never run\")"
    )

    conn = get(build_conn(), "/plugin-routes/unenabled/anything")
    assert conn.status == 404
  end

  test "dispatches to the enabled plugin's call/2 with the method and path segments", %{home: home} do
    write_route_plugin(
      home,
      "PepeRouteTest.Echo",
      "echo",
      "def call(conn, path), do: Plug.Conn.send_resp(conn, 200, conn.method <> \" \" <> Enum.join(path, \"/\"))"
    )

    Pepe.Config.enable_http_route_plugin("echo")

    conn = get(build_conn(), "/plugin-routes/echo/a/b")
    assert conn.status == 200
    assert conn.resp_body == "GET a/b"

    conn2 = post(build_conn(), "/plugin-routes/echo/x")
    assert conn2.status == 200
    assert conn2.resp_body == "POST x"
  end

  test "a crashing plugin answers 500, not a raised request", %{home: home} do
    write_route_plugin(home, "PepeRouteTest.Boom", "boom", "def call(_conn, _path), do: raise(\"kaboom\")")
    Pepe.Config.enable_http_route_plugin("boom")

    conn = get(build_conn(), "/plugin-routes/boom/x")
    assert conn.status == 500
  end

  test "a plugin that already sent a response before crashing is never answered a second time", %{home: home} do
    write_route_plugin(
      home,
      "PepeRouteTest.SentThenCrash",
      "sentcrash",
      "def call(conn, _path) do\n      _conn = Plug.Conn.send_resp(conn, 200, \"partial\")\n      raise(\"boom after send\")\n    end"
    )

    Pepe.Config.enable_http_route_plugin("sentcrash")

    # The controller re-raises rather than attempting a second send_resp/3 on top of the
    # real response the plugin already sent (Plug.ErrorHandler's own `{:plug_conn, :sent}`
    # idiom - the exact same one this controller uses) - so from here, in-process, this
    # is a raised exception, not a graceful conn to assert fields on. In production
    # (Bandit), this is exactly what happens after any Phoenix action crashes post-send:
    # the per-connection process logs it and closes the connection, never a second body.
    assert_raise RuntimeError, "boom after send", fn ->
      get(build_conn(), "/plugin-routes/sentcrash/x")
    end
  end

  test "disabling a previously-enabled route goes back to a plain 404", %{home: home} do
    write_route_plugin(home, "PepeRouteTest.Toggle", "toggle", "def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, \"ok\")")
    Pepe.Config.enable_http_route_plugin("toggle")
    assert get(build_conn(), "/plugin-routes/toggle/x").status == 200

    Pepe.Config.disable_http_route_plugin("toggle")
    assert get(build_conn(), "/plugin-routes/toggle/x").status == 404
  end

  defp write_route_plugin(home, module, prefix, call_body) do
    File.write!(Path.join([home, "plugins", "#{prefix}.exs"]), """
    defmodule #{module} do
      @behaviour Pepe.PluginRoute
      def route_prefix, do: "#{prefix}"
      #{call_body}
    end
    """)
  end
end
