---
title: Authentication
description: Sign in to the dashboard, and protect remote API access with scoped tokens.
---

Pepe has two front doors and each has its own lock. The dashboard is for people, and it is guarded by an optional password plus a network rule that fails closed. The `/v1` HTTP API is for programs, and it is guarded by bearer tokens that carry a scope. On your own machine neither lock is in your way, and neither door opens to the network until you turn its lock on.

## Dashboard authentication

The dashboard is **open by default** so a local install has zero friction: run `pepe serve` on your own machine and browse to it. Authentication is **opt-in**: the moment you set a dashboard password, every page requires signing in. There is no database and no user table. The password is checked in constant time and a signed flag rides in the Phoenix session cookie.

### Enabling it

Set a password either way. If both are present, the config value wins:

```bash
# Option A: an environment variable, so nothing lands in the config file.
export PEPE_DASHBOARD_PASSWORD='a long passphrase'

# Option B: store a reference, so the secret still comes from the environment.
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'

# Check the current state, or turn it off again.
pepe dashboard
pepe dashboard password --clear
```

The value is `${ENV}`-interpolated at read time, so, like every other secret in Pepe, it is never written to `~/.pepe/config.json` in the clear.

With a password set:

* every dashboard route redirects to **`/login`** until you sign in;
* `POST /login` checks the password with a constant-time compare and stores a signed `dashboard_authed` flag in the session cookie;
* a **Sign out** link appears in the sidebar footer, and `DELETE /logout` clears the flag.

Unset the password, by removing the environment variable or the config key, and the dashboard is open again.

### Fail closed: the dashboard is never open to the network without a password

Being "open by default" is safe only because that default is **loopback-only**. A per-request guard enforces it: with **no password set**, the dashboard answers only genuine `localhost` clients. Any request from somewhere else, whether a LAN address, a virtual machine, or a reverse proxy, gets a **403** telling you to set a password. There is no "allow open anyway" switch: reaching the dashboard from off the box means either a password or a tunnel.

The rule, precisely:

| Request comes from | No password | Password set |
|---|---|---|
| `localhost` (loopback, no proxy headers) | allowed | login required |
| LAN, a VM, or another machine | **403** | login required |
| through a proxy (`X-Forwarded-For` present) | **403** | login required |

LAN and private ranges (`192.168.x`, `10.x`, `172.16.x`) count as **public**, not as trusted. The `/v1` API and the `/webhooks` endpoints are unaffected by this rule; they carry their own authentication, described below.

### Reaching it from another machine

Two options are safe:

1. **Set a password** and expose the dashboard behind TLS, using a reverse proxy or a tunnel, so the password and the session cookie are never sent in the clear. When you put a proxy in front, keep the password on, because a proxied request is treated as public.

2. **Keep it on loopback and tunnel in**, so nothing is opened to the network at all:

```bash
pepe serve --tunnel                     # built-in Cloudflare quick tunnel (needs cloudflared)
ssh -L 4000:localhost:4000 you@server   # then browse http://localhost:4000
tailscale serve 4000                    # a private tailnet, no public port
```

`pepe serve --tunnel` runs `cloudflared` and prints a public `https://<...>.trycloudflare.com` URL for the life of the process. Because the tunnel is a proxy, a tunneled request counts as public, so set a dashboard password before using it. The full walkthrough, including named tunnels with a stable URL you choose, is on the [Dashboard](../dashboard/#reaching-it-remotely) page.

`ssh -L` and a Multipass port-forward instead arrive on loopback, so they just work with no password. A VM reached across its virtual network looks remote and is blocked, so forward its port to `localhost`.

### Serving behind a domain or a reverse proxy

Two optional settings make a real deployment behave correctly:

```bash
# The Host header values the dashboard should answer to (loopback names always work).
pepe dashboard hosts dash.example.com

# The reverse proxies whose X-Forwarded-For may be trusted (CIDRs or bare IPs).
pepe dashboard trusted-proxies 127.0.0.1,10.0.0.0/8

# Show the current posture: authentication, hosts, proxies.
pepe dashboard
```

* **Allowed hosts** are a DNS-rebinding defense. With no password, the dashboard accepts only a **loopback** `Host` (`localhost`, `127.0.0.1`, `::1`) and rejects any other name with **400**, which stops a malicious page from rebinding a domain to your machine and driving the local dashboard. When you serve under a real domain, list it here, with a password on. An empty allowlist plus a password accepts any host, because the password is then the gate.
* **Trusted proxies** decide when `X-Forwarded-For` is believed. By default it is ignored and a proxied request is treated as remote, which is the fail-closed choice. List your proxy here and Pepe takes the real client IP from the forwarded chain, so the loopback-versus-remote rule and the login rate limit both see the true peer instead of the proxy.

### Brute-force protection

`POST /login` is rate-limited per client IP, by default 10 attempts every 60 seconds, and a successful login resets the counter. That sits on top of the constant-time password compare and a small delay on each failure. Going over the limit returns **429** with a `Retry-After` header.

### Extending it

The gate is deliberately small and composable: one `on_mount` hook (`PepeWeb.Auth`), one plug (`PepeWeb.NetworkGuard`, backed by `Pepe.Net` and `PepeWeb.RemoteClient`), and the login throttle. Richer schemes, such as OAuth, trusted-proxy identity headers, or per-operator accounts, can slot in without touching each LiveView.

## Authentication and tokens

With **zero tokens configured, the API answers only same-machine (loopback) callers**. A local `curl` or the dashboard works with no token, but any remote caller is refused with `401`, so a server you expose on a network is never anonymous.

Creating the first token flips the switch for everyone. Once any token exists, every request, local or remote, must present a valid one or it is refused with `401`. Minting the first token is what unlocks remote access.

### Minting and managing tokens

You can mint, list, and revoke tokens three ways: the CLI, the dashboard, or by chat.

From the CLI:

```bash
pepe token add [--company CO] [--agent HANDLE] [--label "..."]
pepe token list
pepe token revoke ID
```

In the dashboard, the API tokens page has a form to generate a token (with a company and optional agent scope) and a list to revoke existing ones.

A token is a random string prefixed `pepe_`. Only its SHA-256 hash is stored in the config file; the raw token is printed once at creation and never again. Copy it then. If you lose it, revoke it and mint a new one.

#### Do it by chat

An agent granted the guarded `manage_token` tool can mint, list, and revoke tokens from a conversation. Because a token grants API access, the tool is not read-only: it goes through the permission gate, so you confirm before a token is created, and the raw secret is returned once for you to copy.

> You: Create a token for the acme company, labeled chatwoot.
>
> Agent: (asks you to confirm, then mints it) API token created, scope company acme. Copy it now, it will not be shown again: `pepe_9f2a...`

### Presenting a token

Send it either way an OpenAI-style client would:

```bash
# OpenAI standard: Authorization: Bearer
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

```bash
# Azure OpenAI style: api-key header (accepted as a fallback)
curl http://localhost:4000/v1/chat/completions \
  -H 'api-key: pepe_your_token_here' \
  -H 'content-type: application/json' \
  -d '{ "model": "assistant", "messages": [{"role":"user","content":"hi"}] }'
```

Any OpenAI SDK sends the `Authorization: Bearer` form when you set its `api_key`, so authentication needs no special handling on the client.

### Token scopes

A token carries a scope that decides which agents it can reach. From narrowest to widest:

* **Agent-locked** (`--agent HANDLE`): always runs exactly that agent. The request `model` field is ignored. Hand this to a caller who should only ever reach one specific agent.
* **Company** (`--company CO`): any agent inside that company. A bare `model` name qualifies into that company automatically, and a request for an agent belonging to a different company is refused with `403`.
* **Neither**: the root scope (no company). This is what every command operates on when you do not scope it. It can reach root agents (those with a bare, un-namespaced name) and, uniquely, fall back to bare model connections by name.

### What each scope sees in `GET /v1/models`

| Token | Returns |
|---|---|
| `--company acme` | only `acme` agents |
| `--company globex` | only `globex` agents |
| `--agent acme/support` | only that one agent |
| root (no flag) | root agents (no company) plus raw model connections |
| no token (loopback only) | every agent, all companies, plus raw model connections |

A token never crosses the boundary: an `acme` token can never list or reach a `globex` agent. There is no token that names another company to read it. To get another company's agents, mint that company's own token. For a cross-company operator view, use the CLI (`pepe agent list`) or the dashboard, not a tenant token.

## Multi-tenant routing: give company X its own access

Scopes are how you hand out API access per tenant. To give a company its own key, mint a company-scoped token:

```bash
pepe token add --company acme --label "Acme production"
# prints: pepe_9f2a... (copy it now, shown once)
```

A caller holding that token:

* can reach any agent that belongs to `acme`, by name;
* can send a bare `model` name and have it resolve inside `acme`;
* is refused with `403` if it names an agent in another company;
* sees only `acme` agents from `GET /v1/models`.

```bash
# Allowed: an agent inside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "support", "messages": [{"role":"user","content":"hi"}] }'

# Refused with 403: an agent outside acme.
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer pepe_9f2a...' \
  -H 'content-type: application/json' \
  -d '{ "model": "some-other-company-agent", "messages": [{"role":"user","content":"hi"}] }'
```

To pin a token to exactly one agent (the `model` field is then ignored entirely), add `--agent`:

```bash
pepe token add --company acme --agent acme/support --label "Acme support widget"
```
