# Dashboard authentication

The dashboard is **open by default** so a local install has zero friction: on your
own machine, `mix pepe serve` and browse to it. Authentication is **opt-in** - the
moment you set a dashboard password, every page requires signing in. There is no
database and no user table: the password is checked in constant time and a signed
flag rides in the Phoenix session cookie.

## Enabling it

Set a password one of two ways (the config value wins if both are present):

```bash
# Option A - an env var (nothing lands in the config file)
export PEPE_DASHBOARD_PASSWORD='a long passphrase'

# Option B - store a reference, so the secret still comes from the environment
mix pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# check the current state, or turn it off again
mix pepe dashboard
mix pepe dashboard password --clear
```

The value is `${ENV}`-interpolated at read time, so - like every other secret in
Pepe - it is never written to `~/.pepe/config.json` in the clear.

With a password set:

- every dashboard route redirects to **`/login`** until you sign in;
- `POST /login` checks the password (constant-time compare) and stores a signed
  `dashboard_authed` flag in the session cookie;
- a **Sign out** link appears in the sidebar footer (`DELETE /logout` clears it).

Unset the password (remove the env var / config key) and the dashboard is open
again.

## Fail-closed: the dashboard is never open to the network without a password

Being "open by default" is safe only because that default is **loopback-only**. A
per-request guard (`PepeWeb.NetworkGuard`) enforces it: with **no password set**, the
dashboard answers only genuine `localhost` clients. Any request from somewhere else -
a LAN address, a VM, or through a reverse proxy - gets a **403** telling you to set a
password. There is no "allow open anyway" switch: reaching the dashboard from off-box
means either a password or a tunnel. (This mirrors what mature agent runtimes settled
on after a real incident where an unauthenticated public bind was scanned and abused.)

The rule, precisely:

| Request comes from | No password | Password set |
|---|---|---|
| `localhost` (loopback, no proxy headers) | allowed | login required |
| LAN / VM / another machine | **403** | login required |
| through a proxy (`X-Forwarded-For` present) | **403** | login required |

LAN and private ranges (`192.168.x`, `10.x`, `172.16.x`) count as **public**, not
trusted. The `/v1` API and `/webhooks` are unaffected - they carry their own auth.

### Reaching it from another machine

Two safe options:

1. **Set a password** and expose it behind TLS (a reverse proxy or tunnel), so the
   password and session cookie are never sent in the clear. When you put a proxy in
   front, keep a password on too - a proxied request is treated as public.

2. **Keep it loopback and tunnel in** - nothing is opened to the network:

   ```bash
   mix pepe serve --tunnel                       # built-in Cloudflare quick tunnel (needs cloudflared)
   ssh -L 4000:localhost:4000 you@server         # then browse http://localhost:4000
   multipass exec my-vm -- ...                    # or forward the VM port to your host
   tailscale serve 4000                           # private tailnet, no public port
   ```

   `mix pepe serve --tunnel` runs `cloudflared` and prints a public
   `https://<...>.trycloudflare.com` URL for the life of the process. Because the tunnel
   is a proxy, a tunneled request counts as public, so set a dashboard password before
   using it. `ssh -L` and a Multipass port-forward instead arrive on loopback, so they
   just work with no password; a VM accessed across its virtual network looks remote and
   is blocked, so port-forward it to `localhost`.

   The quick tunnel's URL is random and changes every run. For a **stable URL you
   choose**, use a named tunnel:

   ```bash
   # Headless (best on a server): create the tunnel + hostname in the Cloudflare
   # Zero Trust dashboard, point its service at http://localhost:4000, copy the token.
   CLOUDFLARE_TUNNEL_TOKEN=eyJ... mix pepe serve --tunnel \
     --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

   # Or via a one-time browser login (stores a cert.pem), no token:
   cloudflared tunnel login
   mix pepe serve --tunnel --hostname pepe.example.com
   ```

   With `--token`, the public hostname and its service mapping live in the Cloudflare
   dashboard; `--hostname` is optional there, used only to print the URL at startup. The
   token is a secret, so pass it as a `${ENV_VAR}` reference. Either way the URL is public,
   so keep a dashboard password on.

### Serving behind a domain or a reverse proxy

Two optional settings make a real deployment behave correctly:

```bash
# the Host header(s) the dashboard should answer to (loopback names always work)
mix pepe dashboard hosts dash.example.com

# reverse proxies whose X-Forwarded-For may be trusted (CIDRs or bare IPs)
mix pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

mix pepe dashboard            # show the current posture (auth, hosts, proxies)
```

- **Allowed hosts** are a DNS-rebinding defense. With no password, the dashboard
  accepts only a **loopback** `Host` (`localhost`, `127.0.0.1`, `::1`); any other name
  is rejected with **400**, which stops a malicious page from rebinding a domain to
  your machine and driving the local dashboard. When you serve under a real domain,
  list it here (with a password on). An empty allowlist plus a password accepts any
  host (the password is the gate).
- **Trusted proxies** decide when `X-Forwarded-For` is believed. By default it is
  ignored - a proxied request is treated as remote (fail-closed). List your proxy here
  and Pepe takes the real client IP from the forwarded chain, so the loopback-vs-remote
  rule and the login rate-limit see the true peer, not the proxy.

### Brute-force protection

`POST /login` is rate-limited per client IP (default 10 attempts / 60s; a successful
login resets the counter), on top of a constant-time password compare and a small delay
on each failure. Over the limit returns **429** with a `Retry-After` header.

### Extending it

The gate is intentionally small and composable: one on_mount hook (`PepeWeb.Auth`), one
plug (`PepeWeb.NetworkGuard`, backed by `Pepe.Net` + `PepeWeb.RemoteClient`), and the
login throttle. Richer schemes - OAuth, trusted-proxy identity headers, per-operator
accounts - can slot in without touching each LiveView.

---

[Back to the docs index](../README.md#documentation)
