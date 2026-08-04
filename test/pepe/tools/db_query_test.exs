defmodule Pepe.Tools.DbQueryTest do
  @moduledoc """
  Argument validation and error surfacing for the `db_query` tool. Not tested here (needs a
  real Postgres): an actual successful query, the RLS/`set_config` round trip - see the
  plan's manual verification checklist and `test/pepe/db/query_test.exs` for the
  DB-free tenant-resolution logic this tool delegates to.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Tools.DbQuery

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dbq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "missing connection or query is refused" do
    assert {:error, msg} = DbQuery.run(%{"query" => "SELECT 1"}, %{})
    assert msg =~ "connection"

    assert {:error, msg} = DbQuery.run(%{"connection" => "x"}, %{})
    assert msg =~ "query"
  end

  test "an unknown connection is reported cleanly" do
    assert {:error, msg} = DbQuery.run(%{"connection" => "nope", "query" => "SELECT 1"}, %{})
    assert msg =~ "no database connection named nope"
  end

  test "a write is refused BEFORE any connection is attempted - the statement error, not 'unknown connection'" do
    # Pointing at a connection name that doesn't exist proves the read-only check runs
    # first: if connection lookup happened first, this would report "unknown connection"
    # instead of the write refusal.
    assert {:error, msg} = DbQuery.run(%{"connection" => "also_nope", "query" => "DELETE FROM orders"}, %{})
    assert msg =~ "read-only"
    refute msg =~ "unknown connection"
  end

  test "the tool is never in the always-safe set - it requires authorization like any other risky tool" do
    assert Pepe.Permissions.requires_approval?("db_query")
  end

  test "the spec declares no tenant/company_id parameter - the model can never supply one" do
    props = DbQuery.spec()["function"]["parameters"]["properties"]
    refute Map.has_key?(props, "tenant")
    refute Map.has_key?(props, "company_id")
    refute Map.has_key?(props, "tenant_value")
    assert Map.has_key?(props, "connection")
    assert Map.has_key?(props, "query")
  end

  test "a misconfigured tenant_binding is reported, not silently unscoped" do
    Config.put_db_connection("misconfigured", %{
      "host" => "h",
      "database" => "d",
      "user" => "u",
      "password" => "p",
      "tenant_column" => "company_id"
      # no tenant_binding at all - a real misconfiguration.
    })

    assert {:error, msg} = DbQuery.run(%{"connection" => "misconfigured", "query" => "SELECT 1"}, %{agent: nil})
    assert msg =~ "misconfigured"
  end
end
