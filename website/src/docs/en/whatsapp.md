---
title: WhatsApp
description: Put a Pepe agent behind your WhatsApp number, using Meta's Cloud API.
---

## WhatsApp

WhatsApp uses Meta's Cloud API. Unlike Telegram, where Pepe fetches messages
itself, WhatsApp **delivers** each inbound message to an address on your
server, so Pepe must be reachable from the internet. Every connection gets its
own URL on Pepe's inbound route:

```
/webhooks/:project/:provider/:slug        e.g.  /webhooks/acme/whatsapp/support
```

The `:project` segment is `default` when you are not using extra projects.
Pepe answers Meta's verification handshake on that URL itself, and every
inbound message has its `X-Hub-Signature-256` signature checked against the
app secret before the bound agent runs, so a forged request never reaches the
agent. The reply goes back over the Graph API. `pepe serve` serves this route,
so there is no extra process to run.

You can run as many connections as you like, each bound to its own agent. It is
the same idea as running several Telegram bots.

WhatsApp has a dedicated CLI because it is the most common webhook channel. Add a
connection:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

The connection's credentials (stored under its `config`):

- `phone_number_id`: the sending endpoint id from the Meta app.
- `access_token`: the Graph API bearer token. Store it as `${ENV_VAR}`.
- `app_secret`: verifies the inbound `X-Hub-Signature-256`. Store it as
  `${ENV_VAR}`.
- `verify_token`: any string you choose. Meta echoes it during the subscribe
  handshake. If you omit the flag, the slug is used.

If you leave `--access-token` or `--app-secret` off, the CLI writes a
placeholder reference derived from the slug (for example
`${WA_TOKEN_SUPPORT}` and `${WA_APP_SECRET_SUPPORT}`), so you can fill the real
value into your environment later. The command prints the callback URL and the
verify token. Paste both into the Meta app's webhook configuration, and subscribe
the `messages` field so Meta actually delivers inbound messages to you:

```
https://YOUR_HOST/webhooks/default/whatsapp/support
```

Manage connections:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

`whatsapp list` prints every connection with its callback URL. The other flags on
`whatsapp add` are `--project`, `--trainers`, `--ttl-min`, `--ephemeral`, and
`--commands`, mapping to the per-connection fields described above. The dashboard
adds and edits WhatsApp connections through the same Channels section.

### On the Meta side

Once per number, in your Meta app:

1. Create an app and add the WhatsApp product to it.
2. Note the `phone_number_id` of the number you are connecting.
3. Generate a permanent access token and put it in your environment as
   `${WA_TOKEN_<SLUG>}`.
4. Copy the App Secret and put it in your environment as
   `${WA_APP_SECRET_<SLUG>}`.
5. Point the Callback URL at your connection's slug, enter the verify token, and
   subscribe the `messages` field.

### The two modes

A connection's `--mode` decides how much of Pepe it exposes. The full comparison
is in [Channels](../channels/); for a WhatsApp number it comes down to this:

| | **admin** (yours) | **support** (customer-facing) |
|---|---|---|
| Slash commands | On (`/new` resets) | Off, treated as plain text |
| Who may message | `allowed_numbers`, your own number | Anyone |
| Learns? (`trainers`) | You are a trainer | `[]`, so it never learns from a customer |
| Agent tools | Full | Keep it locked down: safe tools only, since no human is there to approve a risky call |
| Session | Kept | Ephemeral, plus an idle TTL |

### The session

The session is keyed `whatsapp:<agent>:<phone>`. It is the agent's thread with
that one customer, isolated per project through the agent handle. Two things end
it:

- The agent calls the **`end_session`** tool when the exchange is done, which
  clears the context so the customer's next message starts fresh.
- The **idle TTL** (`--ttl-min`, unset means never) evicts a conversation that
  has gone quiet.

Handing a conversation to a specialist needs no extra machinery: the agent simply
calls `send_to_agent`. See [Routing](../routing/).

<div class="note"><strong>24-hour rule.</strong> Meta only allows free-form
replies within 24 hours of the user's last message. Reactive support fits this
naturally. Proactive messages outside the window need pre-approved templates,
which this channel does not send.</div>

### Switching models

`/model` and `/models` only fire on an `admin`-mode connection (see the mode
comparison above); on `support`, they are plain text like any other slash
command. `/models` lists the models available to this connection's project;
`/model` shows the one currently active, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Anyone in an allowed conversation may switch their own session; switching it
**globally** is reserved for **trainers**, the same allowlist that gates
memory. Set `model_switch_locked: true` on the connection to turn
model-switching off entirely for non-trainers. WhatsApp has no button picker
like Telegram's; this is typed only.
