defmodule Pepe.DB.Query do
  @moduledoc """
  Runs a read-only query against a configured `Pepe.DB` connection, tenant-scoped if the
  connection declares a `tenant_column` - and if it does, this is the ONLY place that
  matters for isolation: the tenant value is resolved from operator config and the calling
  agent's own config (`ctx.agent`), never from `sql` or anything else the model supplied,
  and it's set via `set_config(...)` inside the same transaction as the query, every time,
  unconditionally - there is no code path that runs a scoped connection's query without it.

  The real security boundary is Postgres Row-Level Security on the customer's own database,
  enforced by a read-only role with no `BYPASSRLS`. Everything here is defense in depth: a
  bug in `read_only?/1`, or a table with no RLS policy, still can't do more than the
  configured role's own grants allow.
  """

  alias Pepe.Config
  alias Pepe.DB

  # The fixed, documented GUC name every connection's RLS policy is written against
  # (`current_setting('app.pepe_tenant_id', true)`) - not configurable per connection, so
  # there is exactly one convention to get right, not one per connection.
  @tenant_guc "app.pepe_tenant_id"

  # A prefix check, not a full-text scan: scanning the whole query for these words as a
  # defense would also flag a legitimate `WHERE note = 'please delete this later'` (a false
  # positive on ordinary text content). The gap this accepts - a data-modifying CTE like
  # `WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x` - is still stopped, just not
  # here: the read-only Postgres role has no write grants at all, so Postgres itself refuses
  # it regardless of what this regex let through.
  @write_prefix ~r/^\s*(--[^\n]*\n\s*)*(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|GRANT|REVOKE|CREATE|COPY|VACUUM|CALL|EXECUTE|MERGE)\b/i

  @doc "Would `run/3` refuse `sql` as a write, based on its leading statement keyword?"
  @spec read_only?(String.t()) :: boolean()
  def read_only?(sql) when is_binary(sql), do: not Regex.match?(@write_prefix, sql)

  @doc """
  The trusted tenant value for `conn_cfg` given `ctx`, or `:none` when the connection isn't
  tenant-scoped at all (no `tenant_column` configured). Reads only `conn_cfg` (operator
  config, from `Pepe.Config.db_connection/1`) and `ctx.agent` (the calling agent's own
  config struct) - never `ctx[:args]` or anything the model's tool call supplied. An
  unrecognized/missing binding on a connection that DOES declare a `tenant_column` is a
  misconfiguration, and fails closed (`{:error, :bad_tenant_binding}`), never silently "no
  filter."
  """
  @spec resolve_tenant(map(), map()) :: {:ok, term()} | :none | {:error, :bad_tenant_binding}
  def resolve_tenant(%{tenant_column: col}, _ctx) when col in [nil, ""], do: :none

  def resolve_tenant(%{tenant_binding: %{"mode" => "fixed", "value" => v}}, _ctx) when is_binary(v) and v != "",
    do: {:ok, v}

  def resolve_tenant(%{tenant_binding: %{"mode" => "agent_field", "value" => "project"}}, %{agent: agent}),
    do: {:ok, agent.project}

  def resolve_tenant(%{tenant_binding: %{"mode" => "agent_field", "value" => "bare"}}, %{agent: agent}),
    do: {:ok, agent.bare}

  def resolve_tenant(_conn_cfg, _ctx), do: {:error, :bad_tenant_binding}

  @doc """
  Run `sql` (must be read-only) against `conn_name`, tenant-scoped if that connection
  declares it. Returns `{:ok, %Postgrex.Result{}}` or `{:error, reason}`.
  """
  @spec run(String.t(), String.t(), map()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def run(conn_name, sql, ctx) do
    with :ok <- reject_write(sql),
         {:ok, cfg} <- fetch_connection(conn_name),
         {:ok, tenant} <- resolve_tenant(cfg, ctx),
         {:ok, pid} <- DB.ensure(conn_name) do
      Postgrex.transaction(pid, &run_in_transaction(&1, sql, tenant))
    end
  end

  # query/4 (not query!/4) on purpose: query! raises, and an exception raised inside a
  # Postgrex.transaction/2 callback propagates OUT of transaction/2 itself rather than
  # coming back as {:error, _} - explicit rollback/2 is what turns a failure into a
  # clean {:error, reason} return here.
  defp run_in_transaction(conn, sql, tenant) do
    with :ok <- set_tenant(conn, tenant),
         {:ok, result} <- Postgrex.query(conn, sql, []) do
      result
    else
      {:error, reason} -> Postgrex.rollback(conn, reason)
    end
  end

  defp set_tenant(_conn, :none), do: :ok

  defp set_tenant(conn, tenant) do
    case Postgrex.query(conn, "SELECT set_config($1, $2, true)", [@tenant_guc, to_string(tenant)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_write(sql) do
    if read_only?(sql), do: :ok, else: {:error, :write_not_allowed}
  end

  defp fetch_connection(name) do
    case Config.db_connection(name) do
      nil -> {:error, {:unknown_connection, name}}
      cfg -> {:ok, cfg}
    end
  end
end
