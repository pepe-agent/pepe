defmodule PepeWeb.DashboardFileControllerTest do
  @moduledoc """
  The dashboard-only download route `Pepe.Tools.SendFile` hands a "web:<id>" chat a link
  to, instead of the raw server filesystem path nobody at the keyboard can reach. Gated by
  the same dashboard-password check as every other dashboard route - a leaked token alone
  must not be enough once a password is configured.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_dashfile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    prev_pw = System.get_env("PEPE_DASHBOARD_PASSWORD")
    System.put_env("PEPE_HOME", home)
    System.delete_env("PEPE_DASHBOARD_PASSWORD")

    file = Path.join(home, "report.xlsx")
    File.write!(file, "fake-xlsx-bytes")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")

      if prev_pw,
        do: System.put_env("PEPE_DASHBOARD_PASSWORD", prev_pw),
        else: System.delete_env("PEPE_DASHBOARD_PASSWORD")

      File.rm_rf(home)
    end)

    %{xlsx: file}
  end

  # A conn whose Host is a loopback name - real browsers hitting localhost look like
  # this; ConnTest's default "www.example.com" would trip NetworkGuard's anti-rebinding
  # check before the route under test is ever reached.
  defp conn, do: %{build_conn() | host: "localhost"}
  defp set_password(pw), do: Config.save(Map.put(Config.load(), "dashboard", %{"password" => pw}))

  test "streams the registered file as a download, with no password configured", %{xlsx: file} do
    Pepe.Store.put(:dashboard_download, "tok1", %{path: file, filename: "report.xlsx"})

    resp = get(conn(), "/dashboard/files/tok1")

    assert resp.status == 200
    assert resp.resp_body == "fake-xlsx-bytes"
    assert [disposition] = get_resp_header(resp, "content-disposition")
    assert disposition =~ "report.xlsx"
  end

  test "an unknown token 404s instead of leaking a stack trace or a path" do
    resp = get(conn(), "/dashboard/files/does-not-exist")
    assert resp.status == 404
  end

  test "a token whose file was removed from disk since 404s" do
    missing = Path.join(System.tmp_dir!(), "already_gone_#{System.unique_integer([:positive])}.xlsx")
    Pepe.Store.put(:dashboard_download, "tok2", %{path: missing, filename: "already_gone.xlsx"})

    assert get(conn(), "/dashboard/files/tok2").status == 404
  end

  test "with a dashboard password set, an unauthenticated request is redirected to /login instead of served", %{xlsx: file} do
    set_password("s3cret")
    Pepe.Store.put(:dashboard_download, "tok3", %{path: file, filename: "report.xlsx"})

    resp = get(conn(), "/dashboard/files/tok3")

    assert redirected_to(resp) == "/login"
  end
end
