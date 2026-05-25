# API tokens - who may reach the /v1 HTTP API

The `/v1` HTTP API (and its WebSocket twin) is **loopback-open by default**: with no
tokens configured it answers only same-machine callers, and a request from anywhere
else is refused. You don't punch a hole in that - you **mint a token**, and minting
the first one flips the API from "loopback only" to "token required", so a remote
caller can then reach it with `Authorization: Bearer pepe_...`.

You mint, list and revoke tokens with the `manage_token` tool. It grants API access,
so it's permission-gated - each call goes through the human authorize step - and a
regular token's raw value is shown **exactly once** in the result (only its hash is
stored), so tell the user to copy it there and then.

## The scopes - what a token can reach

A token carries a scope, and the scope decides which agents it runs:

- **Principal (default project)** - no `project`, no `agent`. The widest scope: it
  sees every agent in the default project and may pass a bare model connection through
  as the model. Mint one for a trusted local integration.
- **Project** - a `project` slug only. Reaches just that project's agents and
  nothing outside it; a bare model connection is refused. Use it to hand one tenant
  API access.
- **Agent-locked** - a full agent `handle` (like `"acme/support"`). Always runs that
  one agent and **ignores the request's model field** - the caller can't steer it
  elsewhere. The tightest scope for a fixed integration.

```jsonc
// create: mint a Principal token for a local integration
{ "action": "create", "label": "local chatwoot" }

// create: a project-scoped token - reaches only acme's agents
{ "action": "create", "project": "acme", "label": "acme prod" }

// create: an agent-locked token - always runs acme/support
{ "action": "create", "project": "acme", "agent": "acme/support", "label": "support bot" }
```

`list` shows each token's id, scope and label (a regular token only ever shows a safe
fingerprint - its raw value was never stored). `revoke` needs the `id` from `list`.

```jsonc
{ "action": "list" }
{ "action": "revoke", "id": "tok_7f3a" }
```

## Widget tokens - the public exception

A **widget** token is meant to sit in a public page's `<script>` tag (an embedded
chat widget), so it can't be treated as a secret. It is:

- **public and retrievable** - `list` returns its full value any time, and `update`
  edits it in place, instead of forcing a rotation the moment a copy leaks;
- **always agent-locked** - a public credential must pin to one agent, so `agent` is
  **required**;
- **origin-locked** - pass `allowed_origin` (the site's scheme+host). A browser whose
  real `Origin` header doesn't match is refused.

Appearance fields (`title`, `logo`, `color`, `theme`, `greeting`, `position`) are
fetched by the widget script at load time, so they never get baked into the embed
snippet - set them on `create`, change them later with `update` (widget appearance is
the only thing `update` touches; the secret, agent and origin are rotate-only).

```jsonc
// create a widget token for a public site
{ "action": "create", "agent": "acme/support", "widget": true,
  "allowed_origin": "https://example.com",
  "title": "Support", "color": "#ea580c", "theme": "light",
  "greeting": "Hi! How can we help?", "position": "right" }

// restyle it later - no rotation needed
{ "action": "update", "id": "tok_wid_9c1", "color": "#2563eb", "theme": "dark" }
```

Always confirm the scope with the user before you create a token - it's their access
you're handing out.
