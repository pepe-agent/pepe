---
title: Dashboard
description: Use the local web UI to inspect and manage agents, models, channels, and runs.
---

The dashboard is the local web UI started by `pepe serve`. Use it to chat with agents, inspect traces, manage model connections, configure channels, review scheduled work, and generate API tokens without editing JSON by hand.

```bash
pepe serve          # API, dashboard and gateways, all in one process
# then open http://localhost:4000
```

From a source checkout, build the assets once with `mix assets.build` before running `mix pepe serve`.

## Sessions and chat

The dashboard opens on a live list of sessions on the left and a streaming chat panel on the right. Pick a session to read its history and talk to its agent, and the reply streams in token by token. `New chat` starts a fresh session, and each session shows its agent, its model, and its turn count.

Sessions live inside the running process, so run everything from the one `pepe serve` process. The dashboard then sees every session, including the ones that arrived over Telegram.

Risky tools are authorized inline here too. The run pauses and shows an allow/deny prompt, which is the web version of the buttons a Telegram user gets, unless the agent has already pre-approved that tool. The omnipotent owner agent never prompts. See [Security and sandbox](../security/) for how the gate decides.

## Control tower

Chat shows one conversation at a time. **Control tower** shows every live session at once, across every channel - Telegram, the API, the widget, this same dashboard - in a single table: channel, agent, model, turn count, and whether it's running a turn right now. Use it to see everything happening across the whole install without clicking into each conversation individually, filter by agent or channel, jump straight into one (opens it in Chat), or stop one that's stuck mid-turn.

It reflects what's live in this process's memory, refreshed every few seconds - not a history or a cost report. For what a conversation actually cost, see **Traces**' "group by conversation" view instead.

## What the sidebar holds

The left sidebar mirrors the CLI, so almost everything you can do with the `pepe` command you can also do here:

- **Chat**: talk to a session.
- **Control tower**: every live session across every channel, on one screen.
- **Projects**: create, edit and delete tenant scopes and their billing markup. See [Projects](../projects/).
- **Agents**: create, edit and delete agents, with their persona, model, tools, routes, admin scope, and which one is the default.
- **Models**: add, remove and edit model connections, set a per-model price, and pick the default.
- **Usage and billing**: token usage and cost by cycle, per project. See [Usage and billing](../billing/).
- **Learning**: the TimeLearn timeline. See [Learning](../learning/).
- **Scheduled**: create, run and manage scheduled tasks. See [Scheduled tasks](../scheduled/).
- **Watches**: one-shot "notify me when X". See [Watches](../watches/).
- **Channels**: add, remove and edit Telegram bots, applied live. See [Telegram](../telegram/).
- **MCP**: external tool servers. See [MCP servers](../mcp/).
- **Config file**: edit `~/.pepe/config.json` inline, validated on save.

## Keeping it running

`pepe serve` runs in the foreground: closing the terminal or logging out stops it, and the dashboard with it. For a real deployment, install it as a persistent background service instead: launchd on macOS, systemd `--user` on Linux. It survives logout/reboot and restarts itself if it crashes.

```bash
pepe serve install [--port 4000]
pepe serve status
pepe serve uninstall
```

Only works from the installed `pepe` binary, not `mix pepe serve install`. If your model connections reference `${ENV_VAR}` secrets, `install` lists them, because the service starts with a minimal environment and they need to be added to the generated unit/plist by hand.

## Dashboard access

The dashboard is open on localhost by default, which is convenient for local development. The moment you expose it beyond your machine, put it behind a password:

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
