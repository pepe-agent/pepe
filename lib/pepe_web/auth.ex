defmodule PepeWeb.Auth do
  @moduledoc """
  Dashboard authentication gate. Opt-in and stateless: with no dashboard password
  configured the dashboard is open (local dev, as before); set one (via
  `dashboard.password` / `PEPE_DASHBOARD_PASSWORD`) and every LiveView requires a
  signed session established at `/login`. No database - the session flag rides in the
  signed Phoenix session cookie.
  """
  import Phoenix.LiveView, only: [redirect: 2]

  alias Pepe.Config

  @doc "on_mount gate: allow when auth is off or the session is authenticated, else send to /login."
  def on_mount(:ensure, _params, session, socket) do
    if not Config.dashboard_auth_required?() or session["dashboard_authed"] == true do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/login")}
    end
  end
end
