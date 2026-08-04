defmodule PepeWeb.DbConnectionsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_dblive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "lists configured connections, unscoped and tenant-scoped" do
    Config.put_db_connection("plain_pg", %{
      "engine" => "postgres",
      "host" => "h",
      "port" => 5432,
      "database" => "d",
      "user" => "u",
      "password" => "${PW}"
    })

    Config.put_db_connection("billing_pg", %{
      "engine" => "postgres",
      "host" => "h",
      "port" => 5432,
      "database" => "d",
      "user" => "u",
      "password" => "${PW}",
      "tenant_column" => "company_id",
      "tenant_binding" => %{"mode" => "fixed", "value" => "acme"}
    })

    {:ok, _view, html} = live(conn(), "/databases")

    assert html =~ "plain_pg"
    assert html =~ "unscoped"
    assert html =~ "billing_pg"
    assert html =~ "tenant-scoped on company_id"
  end

  test "shows an empty state with no connections configured" do
    {:ok, _view, html} = live(conn(), "/databases")
    assert html =~ "No database connections yet"
  end

  test "never renders a connection's password" do
    Config.put_db_connection("leaky", %{
      "engine" => "postgres",
      "host" => "h",
      "port" => 5432,
      "database" => "d",
      "user" => "u",
      "password" => "sk-live-super-secret"
    })

    {:ok, _view, html} = live(conn(), "/databases")
    refute html =~ "sk-live-super-secret"
  end

  test "opening the new-connection form renders without crashing" do
    {:ok, view, _html} = live(conn(), "/databases")
    html = render_click(view, "conn_new", %{})
    assert html =~ ~s(name="conn[name]")
  end

  test "the tenant mode/value fields only appear once a tenant column is typed" do
    {:ok, view, _html} = live(conn(), "/databases")
    html = render_click(view, "conn_new", %{})
    refute html =~ ~s(name="conn[tenant_mode]")

    html = render_change(view, "conn_change", %{"conn" => %{"tenant_column" => "company_id"}})
    assert html =~ ~s(name="conn[tenant_mode]")
  end

  test "saving a plain connection (no tenant column) persists it unscoped" do
    {:ok, view, _html} = live(conn(), "/databases")
    render_click(view, "conn_new", %{})

    render_submit(view, "conn_save", %{
      "conn" => %{"name" => "acme_db", "host" => "h", "port" => "5432", "database" => "d", "user" => "u", "password" => "${PW}"}
    })

    cfg = Config.db_connection("acme_db")
    assert cfg.host == "h"
    assert cfg.tenant_column == nil
  end

  test "saving with a tenant column but an invalid agent_field value fails validation, saves nothing" do
    {:ok, view, _html} = live(conn(), "/databases")
    render_click(view, "conn_new", %{})

    html =
      render_submit(view, "conn_save", %{
        "conn" => %{
          "name" => "bad",
          "host" => "h",
          "database" => "d",
          "user" => "u",
          "password" => "p",
          "tenant_column" => "company_id",
          "tenant_mode" => "agent_field",
          "tenant_value" => "whatever"
        }
      })

    assert html =~ "Please fix the errors below"
    assert Config.db_connection("bad") == nil
  end

  test "saving with fixed tenant mode persists the tenant_binding" do
    {:ok, view, _html} = live(conn(), "/databases")
    render_click(view, "conn_new", %{})

    render_submit(view, "conn_save", %{
      "conn" => %{
        "name" => "billing_pg",
        "host" => "h",
        "database" => "d",
        "user" => "u",
        "password" => "${PW}",
        "tenant_column" => "company_id",
        "tenant_mode" => "fixed",
        "tenant_value" => "acme-inc"
      }
    })

    cfg = Config.db_connection("billing_pg")
    assert cfg.tenant_column == "company_id"
    assert cfg.tenant_binding == %{"mode" => "fixed", "value" => "acme-inc"}
  end

  test "removing a connection deletes it" do
    Config.put_db_connection("gone", %{
      "engine" => "postgres",
      "host" => "h",
      "port" => 5432,
      "database" => "d",
      "user" => "u",
      "password" => "${PW}"
    })

    {:ok, view, html} = live(conn(), "/databases")
    assert html =~ "gone"

    render_click(view, "conn_remove", %{"name" => "gone"})
    assert Config.db_connection("gone") == nil
  end
end
