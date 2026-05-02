---
title: Dashboard
description: Use the local web UI to inspect and manage agents, models, channels, and runs.
---

The dashboard is the local web UI started by `pepe serve`. Use it to chat with agents, inspect traces, manage model connections, configure channels, review scheduled work, and generate API tokens without editing JSON by hand.

## Keeping it running

`pepe serve` runs in the foreground: closing the terminal or logging out stops it, and the dashboard with it. For a real deployment, install it as a persistent background service instead: launchd on macOS, systemd `--user` on Linux. It survives logout/reboot and restarts itself if it crashes.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Only works from the installed `pepe` binary, not `mix pepe serve install`. If your model connections reference `${ENV_VAR}` secrets, `install` lists them, because the service starts with a minimal environment and they need to be added to the generated unit/plist by hand.

## Dashboard access

The web dashboard is open on localhost by default, which is convenient for local development. The moment you expose it beyond your machine, put it behind a password:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

You can pass a literal password or a `${ENV_VAR}` reference so the secret stays out of the file. Once a password is set, the dashboard requires signing in at `/login`. Clear it with `pepe dashboard password --clear`.

The password is read from `dashboard.password` in the config (interpolated), with a fallback to the `PEPE_DASHBOARD_PASSWORD` environment variable. Two related settings harden a dashboard served behind a domain:

- `pepe dashboard hosts app.example.com,dash.example.com` sets the extra `Host` header values the dashboard accepts. This doubles as the anti DNS-rebinding allowlist.
- `pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8` lists the reverse proxies whose `X-Forwarded-For` header may be trusted. Empty by default, meaning no forwarding header is trusted.

Bound to a public interface with no password, the dashboard fails closed and blocks remote clients until you set one.

## Reaching it remotely

To reach the dashboard or API from outside your machine without opening a port or setting up a reverse proxy, `pepe serve` can open a [Cloudflare](https://www.cloudflare.com/) tunnel (needs `cloudflared` installed):

```bash
pepe serve --tunnel
```

This is a **quick tunnel**: it prints a random `https://<something>.trycloudflare.com` URL that lasts only while the process runs and changes every time. No Cloudflare account needed.

For a **stable URL you choose** on your own domain, use a named tunnel. Two ways:

```bash
# Headless (best on a server): create the tunnel and its public hostname in the
# Cloudflare Zero Trust dashboard, point its service at http://localhost:4000,
# copy the connector token, then:
pepe serve --tunnel --token '${CLOUDFLARE_TUNNEL_TOKEN}' --hostname pepe.example.com

# Or via a one-time browser login (stores a cert.pem), no token:
cloudflared tunnel login
pepe serve --tunnel --hostname pepe.example.com
```

With `--token`, the hostname and its service mapping live in the Cloudflare dashboard; there `--hostname` is optional, used only to print the URL at startup. The token is a secret, so pass it as a `${ENV_VAR}` reference. A tunneled request is always treated as public, so set a dashboard password before relying on any of these.
