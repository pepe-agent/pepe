defmodule Pepe.Tools.DbQuery do
  @moduledoc """
  Run a read-only SQL query against an operator-configured external Postgres database
  (`mix pepe db add`), tenant-scoped by Row-Level Security if the connection declares a
  `tenant_column`. Deliberately NOT in `Pepe.Permissions.@always_safe` - reading a
  customer's database is a risky action even for a `SELECT`, and needs authorization on
  every call like any other risky tool.

  There is no `company_id`/tenant argument in this tool's spec, and that's the whole
  security property: the tenant value comes from operator config and the calling agent's
  own scope (`Pepe.DB.Query.resolve_tenant/2`), never from the model. If asked to "query
  for a different company," this tool has no parameter that does that - say so plainly
  rather than trying to work around it.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "db_query"

  @impl true
  def spec do
    function(
      "db_query",
      "Run a read-only SQL query (SELECT) against a configured external database connection. " <>
        "Use `connection` from the connection names you've been told about. Writes are refused.",
      %{
        "type" => "object",
        "properties" => %{
          "connection" => %{"type" => "string", "description" => "The configured connection name."},
          "query" => %{"type" => "string", "description" => "A read-only SELECT statement."}
        },
        "required" => ["connection", "query"]
      }
    )
  end

  # Waits on a network round trip to the database, like fetch_url.
  @impl true
  def concurrent?, do: true

  @max_result_bytes 30_000

  @impl true
  def run(%{"connection" => connection, "query" => sql}, ctx) when is_binary(connection) and is_binary(sql) do
    case Pepe.DB.Query.run(connection, sql, ctx) do
      {:ok, result} -> {:ok, format(connection, result)}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def run(_args, _ctx), do: {:error, "db_query needs `connection` and `query`"}

  # Query results are content from outside the conversation, same class as fetch_url/
  # web_search/MCP results - wrapped the same way before it reaches the model.
  defp format(connection, %Postgrex.Result{columns: nil}),
    do: Pepe.Security.ExternalContent.mark_untrusted("db_query:#{connection}", "ok (no rows returned)")

  defp format(connection, %Postgrex.Result{columns: columns, rows: rows, num_rows: num_rows}) do
    header = Enum.join(columns, " | ")
    body = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, " | ", &to_string/1) end)
    text = truncate("#{header}\n#{body}\n(#{num_rows} row(s))")
    Pepe.Security.ExternalContent.mark_untrusted("db_query:#{connection}", text)
  end

  defp truncate(text) do
    if byte_size(text) > @max_result_bytes, do: binary_part(text, 0, @max_result_bytes) <> "\n...(truncated)", else: text
  end

  defp error_message(:write_not_allowed), do: "refused: only read-only (SELECT) queries are allowed"
  defp error_message({:unknown_connection, name}), do: "no database connection named #{name} (see mix pepe db list)"

  defp error_message(:bad_tenant_binding),
    do: "this connection is misconfigured (tenant_binding) - fix it with mix pepe db add before retrying"

  defp error_message(%Postgrex.Error{} = e), do: "query failed: #{Exception.message(e)}"
  defp error_message(reason), do: "query failed: #{inspect(reason)}"
end
