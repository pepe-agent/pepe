defmodule PepeWeb.WebhookController do
  @moduledoc """
  The single inbound-webhook endpoint: `/webhooks/:company/:provider/:slug`.

  `GET` answers a provider's verification handshake (echoes the challenge). `POST`
  is an inbound event - the raw body is verified, then `Pepe.Webhooks` runs the
  bound agent and delivers the reply. We respond immediately; the agent work runs
  off-process (providers like Meta retry slow webhooks).
  """
  use PepeWeb, :controller

  alias Pepe.Webhooks

  def verify(conn, %{"company" => c, "provider" => p, "slug" => s} = params) do
    case Webhooks.verify(c, p, s, params) do
      {:ok, challenge} -> send_resp(conn, 200, challenge)
      :error -> send_resp(conn, 403, "forbidden")
    end
  end

  def receive(conn, %{"company" => c, "provider" => p, "slug" => s} = params) do
    payload = Map.drop(params, ["company", "provider", "slug"])
    headers = Map.new(conn.req_headers)

    case Webhooks.handle_inbound(c, p, s, raw_body(conn), payload, headers) do
      :ok -> send_resp(conn, 200, "ok")
      {:respond, status, content_type, body} -> conn |> put_resp_content_type(content_type) |> send_resp(status, body)
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, _} -> send_resp(conn, 404, "not found")
    end
  end

  defp raw_body(conn) do
    conn.assigns[:raw_body] |> List.wrap() |> Enum.reverse() |> IO.iodata_to_binary()
  end
end
