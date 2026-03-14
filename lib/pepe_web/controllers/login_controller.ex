defmodule PepeWeb.LoginController do
  @moduledoc """
  The dashboard login. When a dashboard password is set, `GET /login` shows a small
  form, `POST /login` checks the password (constant-time) and puts a signed
  `dashboard_authed` flag in the session, and `DELETE /logout` clears it. With no
  password configured, everything just redirects home (auth is off).
  """
  use PepeWeb, :controller

  alias Pepe.Config
  alias PepeWeb.LoginThrottle
  alias PepeWeb.RemoteClient

  def new(conn, _params) do
    if Config.dashboard_auth_required?(), do: page(conn, nil), else: redirect(conn, to: "/")
  end

  def create(conn, %{"password" => password}) do
    ip = RemoteClient.ip(conn)

    case LoginThrottle.check(ip) do
      {:error, seconds} ->
        conn
        |> put_status(429)
        |> put_resp_header("retry-after", to_string(seconds))
        |> page(gettext("Too many attempts. Try again in %{s}s.", s: seconds))

      :ok ->
        authenticate(conn, password, ip)
    end
  end

  def create(conn, _params), do: page(put_status(conn, 400), gettext("Enter a password."))

  defp authenticate(conn, password, ip) do
    cond do
      not Config.dashboard_auth_required?() ->
        redirect(conn, to: "/")

      valid?(password) ->
        LoginThrottle.reset(ip)

        conn
        |> configure_session(renew: true)
        |> put_session(:dashboard_authed, true)
        |> redirect(to: "/")

      true ->
        # small constant delay on failure, on top of the per-IP rate limit
        Process.sleep(600)
        page(put_status(conn, 401), gettext("Wrong password."))
    end
  end

  def delete(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: "/login")
  end

  defp valid?(password) do
    case Config.dashboard_password() do
      real when is_binary(real) -> Plug.Crypto.secure_compare(to_string(password), real)
      _ -> false
    end
  end

  # A self-contained dark login page (inline styles, no app assets needed).
  defp page(conn, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()

    err_html =
      if error,
        do: ~s(<p style="color:#f87171;font-size:13px;margin:0 0 12px">#{error}</p>),
        else: ""

    html = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>Pepe · Sign in</title>
    <style>
      *{box-sizing:border-box} body{margin:0;background:#09090b;color:#e4e4e7;
        font:15px/1.5 ui-sans-serif,system-ui,-apple-system,sans-serif;
        display:flex;min-height:100vh;align-items:center;justify-content:center}
      .card{width:320px;padding:28px;border:1px solid #27272a;border-radius:16px;background:#18181b}
      .brand{display:flex;align-items:center;gap:8px;margin-bottom:18px}
      .brand b{font-size:18px} .brand span{font-size:11px;color:#71717a}
      label{display:block;font-size:12px;color:#a1a1aa;margin-bottom:6px}
      input{width:100%;padding:10px 12px;border:1px solid #27272a;border-radius:10px;
        background:#09090b;color:#e4e4e7;font-size:14px;outline:none}
      input:focus{border-color:#f97316}
      button{width:100%;margin-top:14px;padding:10px;border:0;border-radius:10px;
        background:#ea580c;color:#fff;font-weight:600;font-size:14px;cursor:pointer}
      button:hover{background:#f97316}
    </style></head><body>
      <form class="card" method="post" action="/login">
        <div class="brand">
          <svg width="26" height="35" viewBox="16 8 32 44">
            <g stroke="#71717a" stroke-width="3" stroke-linecap="round" fill="none">
              <path d="M26 24 L 21 13"/><path d="M38 24 L 43 13"/></g>
            <circle cx="20.5" cy="12" r="3.2" fill="#e2231a"/><circle cx="43.5" cy="12" r="3.2" fill="#f5b301"/>
            <rect x="18" y="22" width="28" height="27" rx="9" fill="none" stroke="#71717a" stroke-width="3.4"/>
          </svg>
          <div><b>Pepe</b><br><span>#{gettext("Sign in to the dashboard")}</span></div>
        </div>
        #{err_html}
        <input type="hidden" name="_csrf_token" value="#{csrf}">
        <label for="password">#{gettext("Password")}</label>
        <input id="password" name="password" type="password" autofocus autocomplete="current-password">
        <button type="submit">#{gettext("Sign in")}</button>
      </form>
    </body></html>
    """

    conn |> put_resp_content_type("text/html") |> send_resp(conn.status || 200, html)
  end
end
