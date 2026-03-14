defmodule PepeWeb.LoginTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_session: 2]

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_login_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    prev_pw = System.get_env("PEPE_DASHBOARD_PASSWORD")
    System.put_env("PEPE_HOME", home)
    System.delete_env("PEPE_DASHBOARD_PASSWORD")

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})
    Config.save(Map.put(Config.load(), "default_agent", "assistant"))

    # each test starts with a fresh per-IP login counter
    PepeWeb.LoginThrottle.reset({127, 0, 0, 1})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")

      if prev_pw,
        do: System.put_env("PEPE_DASHBOARD_PASSWORD", prev_pw),
        else: System.delete_env("PEPE_DASHBOARD_PASSWORD")

      File.rm_rf(home)
    end)

    :ok
  end

  defp set_dashboard(map), do: Config.save(Map.put(Config.load(), "dashboard", map))
  defp set_password(pw), do: set_dashboard(%{"password" => pw})

  # A conn whose Host is a loopback name (real browsers hitting localhost look like
  # this; ConnTest's default "www.example.com" would trip the anti-rebinding check).
  defp conn, do: %{build_conn() | host: "localhost"}
  defp re(c), do: %{recycle(c) | host: "localhost"}

  test "with no password the dashboard is open and /login redirects home" do
    refute Config.dashboard_auth_required?()
    assert redirected_to(get(conn(), "/login")) == "/"
    # the LiveView mounts (no redirect to /login)
    assert {:ok, _view, _html} = live(conn(), "/")
  end

  test "without a password, a remote (non-loopback) request is blocked fail-closed" do
    refute Config.dashboard_auth_required?()

    # a genuine loopback client is trusted
    assert {:ok, _view, _html} = live(conn(), "/")

    # a request from a LAN/remote address is blocked with 403 + instructions
    remote = %{conn() | remote_ip: {192, 168, 64, 10}}
    assert response(get(remote, "/"), 403) =~ "not reachable from the network"

    # a proxied request (X-Forwarded-For present) loses loopback trust too
    proxied = conn() |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9") |> get("/")
    assert response(proxied, 403)
  end

  test "with a password, a remote request is allowed through to the login gate (not 403)" do
    set_password("s3cret")

    remote = %{conn() | remote_ip: {192, 168, 64, 10}}
    # the guard lets it pass; the login gate then redirects to /login
    assert redirected_to(get(remote, "/")) == "/login"
  end

  test "with a password set, the dashboard requires login" do
    set_password("s3cret")
    assert Config.dashboard_auth_required?()

    # the LiveView gate redirects to /login
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn(), "/")
    # the login page renders
    assert html_response(get(conn(), "/login"), 200) =~ "password"
  end

  test "wrong password is rejected; the right one authenticates and can be revoked" do
    set_password("s3cret")

    # GET /login to obtain a CSRF token + a session cookie, then POST on the same conn
    login = get(conn(), "/login")
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(login, 200))

    wrong = login |> re() |> post("/login", %{"password" => "nope", "_csrf_token" => token})
    assert response(wrong, 401)
    refute get_session(wrong, :dashboard_authed)

    ok = login |> re() |> post("/login", %{"password" => "s3cret", "_csrf_token" => token})
    assert redirected_to(ok) == "/"
    assert get_session(ok, :dashboard_authed) == true

    # an authenticated session mounts the dashboard
    assert {:ok, _view, _html} = live(ok, "/")

    # logout drops the session, so the dashboard stops authenticating
    out = ok |> re() |> delete("/logout")
    assert redirected_to(out) == "/login"
    assert {:error, {:redirect, %{to: "/login"}}} = live(re(out), "/")
  end

  test "Host allowlist: a non-loopback Host is rejected (anti DNS-rebinding), unless allowed" do
    # no password + a foreign Host reaching loopback = a rebinding attempt -> 400
    rebind = %{build_conn() | host: "evil.example.com"}
    assert response(get(rebind, "/"), 400) =~ "Host not allowed"

    # once the host is on the allowlist, it passes the host check
    set_dashboard(%{"allowed_hosts" => ["dash.example.com"]})
    good = %{build_conn() | host: "dash.example.com"}
    assert {:ok, _view, _html} = live(good, "/")

    # a host not on the (now non-empty) allowlist is still rejected
    other = %{build_conn() | host: "nope.example.com"}
    assert response(get(other, "/"), 400)
  end

  test "trusted proxy: X-Forwarded-For is honored only from a configured proxy" do
    set_dashboard(%{"trusted_proxies" => ["127.0.0.1"]})

    # proxy (loopback peer) forwarding a real loopback client -> trusted, served
    local_via_proxy =
      conn() |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1") |> get("/")

    assert html_response(local_via_proxy, 200)

    # same trusted proxy, but the real client is remote -> blocked
    remote_via_proxy =
      conn() |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9") |> get("/")

    assert response(remote_via_proxy, 403)
  end

  test "login is rate-limited per IP (429 after too many attempts)" do
    set_password("s3cret")

    login = get(conn(), "/login")
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(login, 200))

    # config/test.exs caps attempts at 3; the 4th is throttled
    for _ <- 1..3 do
      c = login |> re() |> post("/login", %{"password" => "wrong", "_csrf_token" => token})
      assert response(c, 401)
    end

    blocked = login |> re() |> post("/login", %{"password" => "wrong", "_csrf_token" => token})
    assert response(blocked, 429)
    assert Plug.Conn.get_resp_header(blocked, "retry-after") != []
  end
end
