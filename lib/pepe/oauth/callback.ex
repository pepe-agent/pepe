defmodule Pepe.OAuth.Callback do
  @moduledoc """
  Tiny Plug that backs the local OAuth redirect server. The provider redirects the
  browser to `http://localhost:<port><path>?code=…&state=…` after sign-in; this
  validates `state`, hands the `code` back to the waiting process, and shows a
  friendly "you can close this tab" page.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)
    expected_state = Keyword.fetch!(opts, :state)
    path = Keyword.get(opts, :path, "/auth/callback")

    conn = fetch_query_params(conn)
    params = conn.query_params

    cond do
      conn.request_path != path ->
        send_resp(conn, 404, "not found")

      params["error"] ->
        send(owner, {:oauth_error, ref, params["error"]})
        html(conn, 400, page("Sign-in failed", params["error"]))

      params["state"] != expected_state ->
        send(owner, {:oauth_error, ref, :state_mismatch})
        html(conn, 400, page("Sign-in failed", "state mismatch — please retry"))

      is_binary(params["code"]) and params["code"] != "" ->
        send(owner, {:oauth_code, ref, params["code"]})
        html(conn, 200, page("Signed in ✓", "You can close this tab and return to the terminal."))

      true ->
        send(owner, {:oauth_error, ref, :missing_code})
        html(conn, 400, page("Sign-in failed", "no authorization code received"))
    end
  end

  defp html(conn, status, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  defp page(title, message) do
    """
    <!doctype html><html><head><meta charset="utf-8"><title>Pepe</title>
    <style>body{font-family:system-ui,sans-serif;background:#0f0f17;color:#eee;
    display:grid;place-items:center;height:100vh;margin:0}
    .card{text-align:center}h1{color:#8b5cf6}</style></head>
    <body><div class="card"><h1>#{title}</h1><p>#{message}</p></div></body></html>
    """
  end
end
