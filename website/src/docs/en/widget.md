---
title: Embeddable widget
description: Drop a chat bubble on any website, connected to one Pepe agent.
---

## Embeddable widget

The widget is a chat bubble you drop into any web page with one `<script>` tag.
It renders a floating button, opens into a chat panel, and talks to a Pepe agent
over a live, streaming connection, no dependency and no build step on the page
that embeds it.

### Mint a widget token

A widget's script tag sits in public page source, so it needs its own kind of
token: always locked to one agent, and bound to the site's origin.

```bash
pepe token add --agent support --widget --allowed-origin https://example.com --label "example.com widget"
```

`--widget` requires `--agent`: a public credential always pins to one known-safe
agent, never a whole company or the root scope. `--allowed-origin` is the site's
scheme and host; the widget's connection is refused from anywhere else. See
[Authentication and tokens](./auth/) for the general token model this builds on.

### Embed it

Paste the script tag on the page, pointed at your Pepe server:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="ctx_your_widget_token"
        data-color="#ea580c"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Attribute | What it does | Default |
|---|---|---|
| `data-agent` | Which agent answers. Must match the token's own agent. | `default` |
| `data-token` | The widget token from `token add --widget`. | none |
| `data-server` | The host to connect to. | the script's own host |
| `data-color` | Accent color for the bubble and buttons. | `#ea580c` |
| `data-greeting` | The first message shown before the visitor sends anything. | "Hi! How can I help?" |
| `data-position` | `left` or `right`. | `right` |

No build step, no npm install: `widget.js` and its stylesheet are served
directly by your Pepe server at `/plugin-assets/pepe-widget/`, the same generic
route any future plugin's static assets would use.

### How a visitor's session works

Each visitor gets a random id, stored in their browser's `localStorage`, sent as
the connection's session so a reload continues the same conversation. Under the
hood the widget speaks the same protocol described in [WebSocket](./websocket/):
`prompt` in, `delta` / `done` / `error` / `watch` out.

### Security

- **Origin-bound.** The WebSocket only accepts a widget connection whose browser
  `Origin` matches some registered widget token's `allowed_origin` (or your own
  server's own host). A copy of the script pasted onto an unregistered site is
  refused before it can reach the agent.
- **Agent-locked.** A widget token always runs exactly the one agent it was
  minted for; the widget has no way to ask for a different one.
- **Rate-limited.** Prompts through a widget connection are capped (20 per
  minute by default, overridable with `config :pepe, widget_rate_limit:` /
  `widget_rate_window_s:` if you self-host and need to tune it) so a public,
  in-page-source token can't be hammered. No other surface is affected.

<div class="note"><strong>Give it a narrow agent.</strong> A widget faces the
public internet with no human approving tool calls. Bind it to an agent scoped
to safe, read-only or customer-facing tools, the same guidance as any
customer-facing channel in <a href="./security/">Security and sandbox</a>.</div>

### Do it by chat

An agent with the `manage_token` tool can mint a widget token in conversation:

> Create a widget token for the support agent, allowed from https://example.com.

The agent calls `manage_token` with `action: "create"`, `agent: "support"`,
`widget: true`, and `allowed_origin: "https://example.com"`. Minting a token is
not read-only, so the call goes through the permission gate; the raw token
comes back once in the reply for you to copy into the script tag.
