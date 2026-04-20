---
title: Dashboard
description: Use the local web UI to inspect and manage agents, models, channels, and runs.
---

The dashboard is the local web UI started by `pepe serve`. Use it to chat with agents, inspect traces, manage model connections, configure channels, review scheduled work, and generate API tokens without editing JSON by hand.

## Keeping it running

`pepe serve` runs in the foreground - closing the terminal or logging out stops it, and the dashboard with it. For a real deployment, install it as a persistent background service instead: launchd on macOS, systemd `--user` on Linux. It survives logout/reboot and restarts itself if it crashes.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Only works from the installed `pepe` binary, not `mix pepe serve install`. If your model connections reference `${ENV_VAR}` secrets, `install` lists them - the service starts with a minimal environment, so they need to be added to the generated unit/plist by hand.

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
