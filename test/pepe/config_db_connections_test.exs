defmodule Pepe.ConfigDbConnectionsTest do
  @moduledoc """
  `db_connections` CRUD - the config storage half of the `db_query` tool. See
  `test/pepe/db/query_test.exs` for the tenant-resolution logic and
  `test/pepe/bundle_test.exs` for project extract/restore scoping.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dbconn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "put/get/delete round-trip" do
    assert Config.db_connections() == %{}
    assert Config.db_connection("nope") == nil

    Config.put_db_connection("billing_pg", %{
      "engine" => "postgres",
      "host" => "db.internal",
      "port" => 5432,
      "database" => "billing",
      "user" => "pepe_ro",
      "password" => "${DB_BILLING_PASSWORD}",
      "tenant_column" => "company_id",
      "tenant_binding" => %{"mode" => "fixed", "value" => "acme-inc"}
    })

    assert Map.has_key?(Config.db_connections(), "billing_pg")

    cfg = Config.db_connection("billing_pg")
    assert cfg.name == "billing_pg"
    assert cfg.engine == "postgres"
    assert cfg.host == "db.internal"
    assert cfg.port == 5432
    assert cfg.database == "billing"
    assert cfg.user == "pepe_ro"
    assert cfg.tenant_column == "company_id"
    assert cfg.tenant_binding == %{"mode" => "fixed", "value" => "acme-inc"}

    Config.delete_db_connection("billing_pg")
    assert Config.db_connection("billing_pg") == nil
  end

  test "a connection with no engine defaults to postgres" do
    Config.put_db_connection("x", %{"host" => "h", "database" => "d", "user" => "u", "password" => "p"})
    assert Config.db_connection("x").engine == "postgres"
  end

  test "a connection with no tenant_column/tenant_binding is unscoped" do
    Config.put_db_connection("plain", %{"host" => "h", "database" => "d", "user" => "u", "password" => "p"})
    cfg = Config.db_connection("plain")
    assert cfg.tenant_column == nil
    assert cfg.tenant_binding == nil
  end

  test "the password is stored as the raw ${ENV_VAR} reference, never expanded, and interpolated on read" do
    System.put_env("PEPE_TEST_DB_PW", "s3cr3t")
    on_exit(fn -> System.delete_env("PEPE_TEST_DB_PW") end)

    Config.put_db_connection("x", %{"host" => "h", "database" => "d", "user" => "u", "password" => "${PEPE_TEST_DB_PW}"})

    # The raw config.json file must never contain the resolved secret.
    raw = File.read!(Path.join(Config.home(), "config.json"))
    assert raw =~ "${PEPE_TEST_DB_PW}"
    refute raw =~ "s3cr3t"

    # But the getter used at connection time resolves it.
    assert Config.db_connection("x").password == "s3cr3t"
  end

  test "literal_secrets/1 flags a raw password left in a db_connections entry" do
    Config.put_db_connection("leaky", %{"host" => "h", "database" => "d", "user" => "u", "password" => "sk-live-1234567890abcdef123456"})
    Config.put_db_connection("clean", %{"host" => "h", "database" => "d", "user" => "u", "password" => "${OK_VAR}"})

    config = Config.home() |> Path.join("config.json") |> File.read!() |> Jason.decode!()

    secrets = Config.literal_secrets(config)
    assert "db_connection:leaky" in secrets
    refute "db_connection:clean" in secrets
  end
end
