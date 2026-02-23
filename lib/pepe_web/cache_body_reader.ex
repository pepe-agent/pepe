defmodule PepeWeb.CacheBodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that stashes the raw request body for webhook paths,
  so providers can verify signatures (e.g. WhatsApp's `X-Hub-Signature-256`) over
  the exact bytes Meta signed - the parsed map isn't enough. Only `/webhooks/*` is
  cached, so nothing else pays the memory cost.
  """

  @doc false
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if String.starts_with?(conn.request_path, "/webhooks/") do
        update_in(conn.assigns[:raw_body], fn chunks -> [body | chunks || []] end)
      else
        conn
      end

    {:ok, body, conn}
  end
end
