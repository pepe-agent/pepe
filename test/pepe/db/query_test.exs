defmodule Pepe.DB.QueryTest do
  @moduledoc """
  `read_only?/1` and `resolve_tenant/2` - the two pure, DB-free pieces of `Pepe.DB.Query`.
  The actual `Postgrex.transaction/2` + `set_config` + RLS round trip needs a real
  Postgres and is not exercised here; see the plan's manual verification checklist.
  """
  use ExUnit.Case, async: true

  alias Pepe.Config.Agent
  alias Pepe.DB.Query

  describe "read_only?/1" do
    test "accepts a plain SELECT" do
      assert Query.read_only?("SELECT * FROM orders")
    end

    test "accepts SELECT with leading whitespace and a line comment" do
      assert Query.read_only?("  -- get the orders\n  SELECT * FROM orders")
    end

    test "accepts a read-only WITH ... SELECT" do
      assert Query.read_only?("WITH recent AS (SELECT * FROM orders) SELECT * FROM recent")
    end

    test "is case-insensitive" do
      assert Query.read_only?("select * from orders")
      refute Query.read_only?("delete from orders")
    end

    for kw <- ~w(INSERT UPDATE DELETE DROP ALTER TRUNCATE GRANT REVOKE CREATE COPY VACUUM CALL EXECUTE MERGE) do
      test "rejects #{kw}" do
        refute Query.read_only?(unquote(kw) <> " something")
      end
    end

    test "rejects a write hidden after a leading comment" do
      refute Query.read_only?("-- looks innocent\nDROP TABLE users")
    end
  end

  describe "resolve_tenant/2" do
    @agent %Agent{name: "acme/support", project: "acme", bare: "support"}

    test "no tenant_column at all -> :none, regardless of ctx" do
      assert Query.resolve_tenant(%{tenant_column: nil, tenant_binding: nil}, %{}) == :none
      assert Query.resolve_tenant(%{tenant_column: "", tenant_binding: %{"mode" => "fixed", "value" => "x"}}, %{}) == :none
    end

    test "fixed mode returns the literal value, ignoring ctx entirely" do
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "fixed", "value" => "acme-inc"}}
      assert Query.resolve_tenant(cfg, %{}) == {:ok, "acme-inc"}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:ok, "acme-inc"}
    end

    test "agent_field/project resolves off the calling agent's project" do
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "agent_field", "value" => "project"}}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:ok, "acme"}
    end

    test "agent_field/bare resolves off the calling agent's bare handle" do
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "agent_field", "value" => "bare"}}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:ok, "support"}
    end

    test "a tenant_column with no binding at all fails closed, not open" do
      cfg = %{tenant_column: "company_id", tenant_binding: nil}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:error, :bad_tenant_binding}
    end

    test "an unrecognized binding mode fails closed" do
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "something_else", "value" => "x"}}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:error, :bad_tenant_binding}
    end

    test "agent_field with an unrecognized value (not project/bare) fails closed" do
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "agent_field", "value" => "something_else"}}
      assert Query.resolve_tenant(cfg, %{agent: @agent}) == {:error, :bad_tenant_binding}
    end

    test "never reads a tenant value from ctx.args - there is no such thing" do
      # A model-controlled arg map, even if it happens to carry a "tenant"/"company_id" key,
      # must never be read by resolve_tenant/2 - only conn_cfg and ctx.agent may supply the
      # value. This asserts the fixed-mode result is unaffected by anything in ctx besides
      # :agent, which is the whole point.
      cfg = %{tenant_column: "company_id", tenant_binding: %{"mode" => "fixed", "value" => "real-tenant"}}
      poisoned_ctx = %{agent: @agent, args: %{"company_id" => "attacker-supplied-tenant"}}
      assert Query.resolve_tenant(cfg, poisoned_ctx) == {:ok, "real-tenant"}
    end
  end
end
