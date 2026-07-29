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

## The permissions - what a token may do with what it reaches

Scope answers *whose* data; permissions answer *what may be done with it*. Defaults keep
every existing token exactly as it was: a token **may** chat and **may not** read usage.

- `chat` (default `true`) - may run agents.
- `usage` (default `false`) - may read `/v1/usage`, the billing figures.
- `prices` (default `"billable"`) - how much money a usage read shows: `"billable"` is
  what the client pays (list price with the project's markup), `"list"` is the same
  tokens with no markup, `"all"` adds our cost and the margin.
- `usage_content` (default `false`) - a run's detail may include the prompt and each
  tool's arguments and output.

Give a **client** `chat: false, usage: true` and leave `prices` at `"billable"`. Never give
a client `"all"` or `usage_content`: the first hands over the margin, the second hands over
transcripts. A widget token can never read usage at all.

```jsonc
// a read-only billing token for a client's finance system
{ "action": "create", "project": "acme", "chat": false, "usage": true, "label": "acme billing" }

// change what an existing token may do, without rotating its secret
{ "action": "permissions", "id": "tok_7f3a", "prices": "list" }
{ "action": "permissions", "id": "tok_7f3a", "usage": false }
```

Only the keys you pass to `permissions` change; the rest stay as they were. If the user
asks for a token "to see the usage", that is `chat: false, usage: true` - confirm whether
they want the markup shown before you pick `prices`.

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
