defmodule PepeWeb.AssetControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_actrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "serves the built-in widget's JS with the right content type" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/widget.js")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> Enum.at(0) =~ "javascript"
    assert conn.resp_body =~ "Pepe embeddable chat widget"
  end

  test "serves the built-in widget's CSS with the right content type" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/widget.css")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> Enum.at(0) =~ "css"
    assert conn.resp_body =~ "pepe-widget-bubble"
  end

  test "404s an unknown plugin" do
    conn = get(build_conn(), "/plugin-assets/does-not-exist/widget.js")
    assert conn.status == 404
  end

  test "404s a real plugin's undeclared file (e.g. its manifest)" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/manifest.json")
    assert conn.status == 404
  end

  test "404s a path-traversal attempt" do
    conn = get(build_conn(), "/plugin-assets/pepe-widget/..%2F..%2F..%2Fmix.exs")
    assert conn.status == 404
  end
end
