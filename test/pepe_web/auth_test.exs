defmodule PepeWeb.AuthTest do
  @moduledoc """
  The dashboard's `on_mount` gate. It is the whole authorization boundary for every dashboard
  LiveView, and it was untested - a regression here would silently open the dashboard (or lock the
  operator out). Pinned directly.
  """
  use ExUnit.Case, async: false

  alias PepeWeb.Auth

  setup do
    # A clean, empty home so `dashboard_password` finds no password in config and falls to the env
    # var, which each test controls.
    home = Path.join(System.tmp_dir!(), "pepe_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    prev_pw = System.get_env("PEPE_DASHBOARD_PASSWORD")
    System.put_env("PEPE_HOME", home)
    System.delete_env("PEPE_DASHBOARD_PASSWORD")

    on_exit(fn ->
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      if prev_pw, do: System.put_env("PEPE_DASHBOARD_PASSWORD", prev_pw), else: System.delete_env("PEPE_DASHBOARD_PASSWORD")
      File.rm_rf(home)
    end)

    %{socket: %Phoenix.LiveView.Socket{}}
  end

  test "auth off (no password): mounts through regardless of the session", %{socket: socket} do
    assert {:cont, _} = Auth.on_mount(:ensure, %{}, %{}, socket)
    assert {:cont, _} = Auth.on_mount(:ensure, %{}, %{"dashboard_authed" => false}, socket)
  end

  test "auth on + an unauthenticated session: halts to /login", %{socket: socket} do
    System.put_env("PEPE_DASHBOARD_PASSWORD", "secret")

    assert {:halt, halted} = Auth.on_mount(:ensure, %{}, %{}, socket)
    assert {:redirect, %{to: "/login"}} = halted.redirected
    assert {:halt, _} = Auth.on_mount(:ensure, %{}, %{"dashboard_authed" => false}, socket)
  end

  test "auth on + an authenticated session: mounts through", %{socket: socket} do
    System.put_env("PEPE_DASHBOARD_PASSWORD", "secret")

    assert {:cont, _} = Auth.on_mount(:ensure, %{}, %{"dashboard_authed" => true}, socket)
  end
end
