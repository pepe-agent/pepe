defmodule PepeWeb.NetworkGuard do
  @moduledoc """
  Fail-closed network guard for the dashboard. The rule (a posture matured after a real
  exposure incident where an unauthenticated public bind was scanned and abused): **the
  dashboard is only reachable without a password from a genuine loopback client**.
  Everything else - LAN, a VM (Multipass/Docker), a reverse proxy - counts as public and
  must authenticate.

  Two checks, in order:

    1. **Host allowlist (anti DNS-rebinding).** The `Host` header must be a loopback
       name, or a configured `dashboard.allowed_hosts` entry, otherwise it is rejected -
       except once a password is set and no allowlist is configured, where any host is
       accepted (the password is the gate and the intended domain is unknown).
    2. **Loopback-vs-remote.** With no password, only a genuine loopback client (see
       `PepeWeb.RemoteClient`, which honors the trusted-proxy allowlist) is served; a
       remote or untrusted-proxied request gets a 403 with instructions.

  There is deliberately no "allow open" override: reach it from elsewhere by setting a
  password (one command) or by binding to loopback and tunneling in.
  """
  import Plug.Conn

  alias Pepe.Config
  alias PepeWeb.RemoteClient

  @behaviour Plug

  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1] 0.0.0.0)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not host_allowed?(conn) -> conn |> bad_host() |> halt()
      Config.dashboard_auth_required?() -> conn
      RemoteClient.local_direct?(conn) -> conn
      true -> conn |> locked() |> halt()
    end
  end

  defp host_allowed?(conn) do
    host = conn.host |> to_string() |> String.downcase()
    allowed = Config.dashboard_allowed_hosts() |> Enum.map(&String.downcase/1)

    cond do
      host in @loopback_hosts -> true
      String.starts_with?(host, "127.") -> true
      host in allowed -> true
      # An explicit allowlist is set and this host isn't in it: reject.
      allowed != [] -> false
      # No allowlist: a password gates access, so any host is fine; without one, a
      # non-loopback host is a rebinding attempt (or a misconfig) and is rejected.
      true -> Config.dashboard_auth_required?()
    end
  end

  defp bad_host(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Host not allowed. Add it to dashboard.allowed_hosts to serve this name.")
  end

  defp locked(conn) do
    body = """
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1"><title>Pepe · Locked</title>
    <style>
      *{box-sizing:border-box} body{margin:0;background:#09090b;color:#e4e4e7;
        font:15px/1.6 ui-sans-serif,system-ui,-apple-system,sans-serif;
        display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}
      .card{max-width:440px;padding:28px;border:1px solid #27272a;border-radius:16px;background:#18181b}
      h1{font-size:17px;margin:0 0 10px} p{color:#a1a1aa;font-size:14px;margin:0 0 12px}
      code{background:#09090b;border:1px solid #27272a;border-radius:6px;padding:2px 6px;font-size:13px;color:#fbbf24}
      .hint{font-size:12px;color:#71717a;margin-top:14px}
    </style></head><body>
      <div class="card">
        <h1>🔒 This dashboard is not reachable from the network without a password.</h1>
        <p>You reached it from outside the local machine. For safety, Pepe serves the
        dashboard openly only to <strong>localhost</strong>.</p>
        <p>To allow this access, set a password on the server:</p>
        <p><code>mix pepe dashboard password '&lt;your password&gt;'</code></p>
        <p class="hint">Or keep it private: bind to <code>127.0.0.1</code> and tunnel in
        (SSH <code>-L</code>, a Multipass port-forward, or Tailscale). The
        <code>/v1</code> API and webhooks are unaffected - they use their own auth.</p>
      </div>
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, body)
  end
end
