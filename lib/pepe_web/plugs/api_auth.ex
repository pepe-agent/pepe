defmodule PepeWeb.ApiAuth do
  @moduledoc """
  Bearer-token authentication for the `/v1` API.

  Auth follows a fail-safe default that stays convenient locally but never leaves a
  network-exposed server open:

    * Tokens configured: a valid token is required from every caller, local or remote.
      The request is tagged with the token's scope (`%{company, agent}`), which the
      controller enforces. A missing or unknown token gets a 401 in the OpenAI error
      shape.
    * No tokens configured: only same-machine (loopback) callers are let in, tagged
      `:unrestricted`. A remote caller is refused with a 401, so an exposed server is
      never anonymous. Minting the first token is what unlocks remote access.

  The token may arrive either way clients send it:

    * `Authorization: Bearer ctx_...` - the OpenAI standard (used by the official SDKs).
    * `api-key: ctx_...` - the Azure OpenAI style, accepted as a fallback.
  """

  import Plug.Conn

  alias Pepe.ApiToken
  alias Pepe.Config

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      Config.api_auth_required?() ->
        with raw when is_binary(raw) <- presented_token(conn),
             scope when is_map(scope) <- Config.verify_api_token(raw) do
          assign(conn, :api_scope, scope)
        else
          _ -> deny(conn)
        end

      loopback?(conn.remote_ip) ->
        assign(conn, :api_scope, :unrestricted)

      true ->
        deny(conn)
    end
  end

  @doc """
  Is this peer address on the same machine (loopback)? Covers IPv4 `127.0.0.0/8`, IPv6
  `::1`, and the IPv4-mapped-IPv6 form of a `127.x` address. Shared with the WebSocket
  entry point so both surfaces gate remote access identically.
  """
  @spec loopback?(:inet.ip_address()) :: boolean()
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _}) when high in 0x7F00..0x7FFF, do: true
  def loopback?(_), do: false

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
