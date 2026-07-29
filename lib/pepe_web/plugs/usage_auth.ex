defmodule PepeWeb.UsageAuth do
  @moduledoc """
  The gate in front of `/v1/usage`, and the only place a usage request's authority is
  decided.

  `PepeWeb.ApiAuth` has already established *who* is calling; this answers whether that
  caller may read the billing record at all, and resolves once - into `conn.assigns.usage_ctx`
  - everything the endpoints are then allowed to do with it:

    * `projects` - `:all`, or the single project the token is confined to
    * `agent` - the one agent it is pinned to, or `nil` for a whole project
    * `view` - how much of the money it may see (`"billable"` / `"list"` / `"all"`)
    * `content?` - whether a run's detail may include conversation content

  Resolved here rather than per action so no endpoint can be added later that forgets one of
  them: an action that reads `usage_ctx` cannot have skipped this plug, because that is where
  the assign comes from.
  """

  import Plug.Conn

  alias Pepe.ApiScope

  def init(opts), do: opts

  def call(conn, _opts) do
    scope = conn.assigns[:api_scope] || :unrestricted

    if ApiScope.usage?(scope) do
      assign(conn, :usage_ctx, %{
        projects: ApiScope.usage_scope(scope),
        agent: ApiScope.usage_agent(scope),
        view: ApiScope.prices(scope),
        content?: ApiScope.usage_content?(scope)
      })
    else
      deny(conn)
    end
  end

  defp deny(conn) do
    body =
      Jason.encode!(%{
        error: %{
          message: "this token is not allowed to read usage",
          type: "invalid_request_error",
          code: "usage_not_permitted"
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, body)
    |> halt()
  end
end
