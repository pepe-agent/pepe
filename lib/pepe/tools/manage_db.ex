defmodule Pepe.Tools.ManageDb do
  @moduledoc """
  Let an agent register and inspect **external Postgres database connections** for the
  `db_query` tool, from a conversation.

  **Postgres only, and RLS is the actual boundary.** A connection can declare a
  `tenant_column` (e.g. `"company_id"`), but that alone protects nothing - the operator's
  own database needs Row-Level Security policies enforcing it (a dedicated role with
  `NOBYPASSRLS`, `CREATE POLICY ... USING (company_id = current_setting('app.pepe_tenant_id', true))`
  on every table that needs it). This tool only binds a trusted tenant value to the
  connection; it cannot verify the operator's schema is actually protected.

  There is no way to set a tenant value **per query** - only per connection, at `add` time,
  from `tenant_binding` (a fixed value, or the calling agent's own `project`/`bare` name).
  This is deliberate: a tenant value the model could pass per call is exactly the thing this
  whole feature exists to prevent.

  It's a risky tool (in the allowlist + through the permission gate). Same "never refuse a
  raw credential, warn and tell them to rotate it" policy as `manage_mcp`/`manage_plugin` -
  see `Pepe.Secrets`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "manage_db"

  @impl true
  def spec do
    function(
      "manage_db",
      """
      Register and inspect external Postgres database connections for the db_query tool. \
      Postgres only. Put the password as a ${ENV_VAR} reference, never raw. Actions:
      - add: register a connection - needs `name`, `host`, `port`, `database`, `user`, `password`. \
        Optional `tenant_column` (e.g. "company_id") plus `tenant_mode` ("fixed" with \
        `tenant_value`, or "agent_field" with `tenant_value` set to "project" or "bare" to \
        resolve from the calling agent's own scope). Omit both to leave the connection unscoped.
      - list: show configured connections and whether each is tenant-scoped.
      - remove: delete a connection - needs `name`.

      A tenant_column with no working Row-Level Security policy on the operator's own database \
      protects nothing - say so plainly if asked to confirm isolation without knowing whether \
      RLS is actually set up there; this tool cannot verify that.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(add list remove)},
          "name" => %{"type" => "string", "description" => "The connection name."},
          "host" => %{"type" => "string"},
          "port" => %{"type" => "integer"},
          "database" => %{"type" => "string"},
          "user" => %{"type" => "string"},
          "password" => %{"type" => "string", "description" => "Prefer ${ENV_VAR}."},
          "tenant_column" => %{"type" => "string", "description" => "e.g. \"company_id\". Omit for an unscoped connection."},
          "tenant_mode" => %{"type" => "string", "enum" => ~w(fixed agent_field)},
          "tenant_value" => %{
            "type" => "string",
            "description" => "A literal value (fixed mode) or \"project\"/\"bare\" (agent_field mode)."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_db needs an `action`"}

  defp dispatch("list", _args), do: {:ok, render_list()}
  defp dispatch("add", args), do: add(args)
  defp dispatch("remove", %{"name" => name}), do: remove(name)
  defp dispatch(other, _args), do: {:error, "unknown or incomplete action: #{other}"}

  defp add(args) do
    with {:ok, name} <- fetch(args, "name"),
         {:ok, definition} <- definition(args) do
      Config.put_db_connection(name, definition)
      secrets = Pepe.Secrets.plaintext_in(definition)
      saved = "Database connection #{name} saved."
      {:ok, saved <> Pepe.Secrets.warning(secrets, "the database connection #{name}")}
    end
  end

  defp definition(args) do
    with {:ok, host} <- fetch(args, "host"),
         {:ok, database} <- fetch(args, "database"),
         {:ok, user} <- fetch(args, "user"),
         {:ok, password} <- fetch(args, "password"),
         {:ok, tenant_binding} <- tenant_binding(args) do
      {:ok,
       %{
         "engine" => "postgres",
         "host" => host,
         "port" => args["port"] || 5432,
         "database" => database,
         "user" => user,
         "password" => password,
         "tenant_column" => args["tenant_column"],
         "tenant_binding" => tenant_binding
       }}
    end
  end

  defp tenant_binding(%{"tenant_column" => col} = args) when is_binary(col) and col != "" do
    with {:ok, mode} <- fetch(args, "tenant_mode"),
         {:ok, value} <- fetch(args, "tenant_value"),
         :ok <- validate_tenant_mode(mode, value) do
      {:ok, %{"mode" => mode, "value" => value}}
    end
  end

  defp tenant_binding(_args), do: {:ok, nil}

  defp validate_tenant_mode("fixed", _value), do: :ok
  defp validate_tenant_mode("agent_field", value) when value in ["project", "bare"], do: :ok
  defp validate_tenant_mode("agent_field", _value), do: {:error, ~s(tenant_value must be "project" or "bare" for agent_field mode)}
  defp validate_tenant_mode(mode, _value), do: {:error, "unknown tenant_mode: #{mode} (expected \"fixed\" or \"agent_field\")"}

  defp remove(name) do
    case Config.db_connection(name) do
      nil ->
        {:error, "no database connection named #{name}"}

      _ ->
        Config.delete_db_connection(name)
        {:ok, "Database connection #{name} removed."}
    end
  end

  ###
  ### helpers
  ###

  defp render_list do
    case Config.db_connections() do
      m when map_size(m) == 0 ->
        "No database connections configured."

      conns ->
        Enum.map_join(conns, "\n", &connection_line/1)
    end
  end

  defp connection_line({name, %{"tenant_column" => col}}) when is_binary(col) and col != "",
    do: "• #{name}: tenant-scoped on #{col}"

  defp connection_line({name, _cfg}), do: "• #{name}: unscoped"

  defp fetch(args, key) do
    case args[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "#{key} is required"}
    end
  end
end
