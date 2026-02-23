defmodule PepeWeb.ApiAuth do
  @moduledoc """
  Bearer-token authentication for the `/v1` API.

  When no tokens are configured the API is **open** (single-tenant default) and every
  request is tagged `:unrestricted`. Once any token exists, a valid token is required;
  the request is tagged with the token's scope (`%{company, agent}`), which the
  controller enforces. A missing or unknown token gets a 401 in the OpenAI error shape.

  The token may arrive either way clients send it:

    * `Authorization: Bearer ctx_...` - the OpenAI standard (used by the official SDKs).
    * `api-key: ctx_...` - the Azure OpenAI style, accepted as a fallback.
  """

  import Plug.Conn

  alias Pepe.ApiToken
  alias Pepe.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    if Config.api_auth_required?() do
      with raw when is_binary(raw) <- presented_token(conn),
           scope when is_map(scope) <- Config.verify_api_token(raw) do
        assign(conn, :api_scope, scope)
      else
        _ -> deny(conn)
      end
    else
      assign(conn, :api_scope, :unrestricted)
    end
  end

  # OpenAI style (`Authorization: Bearer <token>`) first, then Azure style
  # (`api-key: <token>`, the raw token with no scheme).
  defp presented_token(conn) do
    bearer = conn |> get_req_header("authorization") |> List.first() |> ApiToken.from_header()

    cond do
      is_binary(bearer) -> bearer
      key = conn |> get_req_header("api-key") |> List.first() -> String.trim(key)
      true -> nil
    end
  end

  defp deny(conn) do
    body =
      Jason.encode!(%{
        error: %{
          message: "invalid or missing API token",
          type: "invalid_request_error",
          code: "invalid_api_key"
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
