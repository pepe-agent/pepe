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

### Or do it from the dashboard

The Channels section has a **+ Widget** button that opens a form right there -
label, agent, allowed origin, and appearance - no separate trip to the tokens
page. After creating one, the dashboard shows the full `<script>` tag already
filled in with the real token, agent, and your server's own address, ready to
copy and paste. Existing widgets keep a collapsible snippet too, and their raw
token stays visible any time - unlike a regular API token, a widget token's
value isn't a secret worth hiding (see [Security](#security) below), so
there's no "copy it now, you won't see it again." Changing which agent or
origin a widget uses still means minting a new one and revoking the old
(those stay rotate-only), but appearance can be edited in place at any time.

### Set the look from the dashboard

Title, logo, color, theme, greeting and position don't have to live in the
`<script>` tag at all - set them on the widget token instead (at creation, or
later via the **Edit appearance** button on an existing widget) and the
script fetches them at load time. Precedence is per field, not all-or-nothing:
**the token's value wins whenever it's set**; a field left unset on the token
falls back to the tag's own `data-*` attribute, then to the built-in default.
So this is entirely optional (a plain `data-token` embed with nothing else
keeps working exactly as before), and the two can mix freely - color from the
dashboard, greeting hardcoded in the tag, say. The point is that a color or
greeting tweak never needs a site redeploy: change it on the dashboard,
reload the page, done.

### Embed it

Paste the script tag on the page, pointed at your Pepe server:

```html
<script src="https://your-pepe-host/plugin-assets/pepe-widget/widget.js"
        data-agent="support"
        data-token="pepe_your_widget_token"
        data-title="Chat"
        data-logo="https://example.com/logo.png"
        data-color="#ea580c"
        data-theme="dark"
        data-greeting="Hi! How can I help?"
        data-position="right"></script>
```

| Attribute | What it does | Default |
|---|---|---|
| `data-agent` | Which agent answers. Must match the token's own agent. | `default` |
| `data-token` | The widget token from `token add --widget`. | none |
| `data-server` | The host to connect to. | the script's own host |
| `data-title` | The panel header's text. | "Chat" |
| `data-logo` | A small square image, used for the bubble icon and next to the header title. Omit it to keep the plain emoji bubble. | none |
| `data-color` | Accent color for the bubble, header and buttons. | `#ea580c` |
| `data-theme` | `dark` or `light` - the panel's base colors below the header. | `dark` |
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

The header's 🧹 button starts a new conversation right away: it closes the
current connection, clears the panel, and reconnects under a fresh session id.
That id is persisted immediately, so even a full page reload keeps talking to
the new conversation, not the old one.

In the dashboard's Chat page, widget conversations group under **Widget**, one
subgroup per site (the token's `allowed_origin`) - so running more than one
widget across different sites keeps their conversations easy to tell apart,
distinct from the dashboard's own built-in chat.

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
- **Not treated as a secret.** A widget token's raw value sits in public HTML
  already, readable with "view source" on the embedding site - so, unlike a
  regular API token, it's stored recoverable and stays visible in the
  dashboard/`manage_token list`. What actually protects it is the three
  points above, not hiding the string.

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
comes back in the reply for you to copy into the script tag - and stays
available any time with `action: "list"`, since a widget token isn't a secret
worth hiding.

Appearance works the same way, on either action - pass any of `title`, `logo`,
`color`, `theme`, `greeting`, `position` on `create`, or later with
`action: "update"` and the token's `id`:

> Change the support widget's greeting to "Hey! Need a hand?" and set its color to #2563eb.

The agent calls `manage_token` with `action: "update"`, `id: "<the token's id>"`,
`greeting: "Hey! Need a hand?"`, and `color: "#2563eb"` - a field left out of
the call keeps its current value.
