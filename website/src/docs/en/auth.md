---
title: Authentication
description: Protect remote API access with scoped tokens.
---

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
