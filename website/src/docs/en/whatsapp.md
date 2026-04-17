---
title: WhatsApp
description: Connect WhatsApp Cloud API webhooks to Pepe agents.
---

## WhatsApp

WhatsApp uses Meta's Cloud API. It has a dedicated CLI because it is the most
common webhook channel. Add a connection:

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
`${WA_TOKEN_SUPPORT}`), so you can fill the real value into your environment
later. The command prints the callback URL and the verify token. Paste both
into the Meta app's webhook configuration:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Manage connections:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

The other flags on `whatsapp add` are `--company`, `--trainers`, `--ttl-min`,
`--ephemeral`, and `--commands`, mapping to the per-connection fields described
above. The dashboard adds and edits WhatsApp connections through the same
Channels section.

<div class="note"><strong>24-hour rule.</strong> Meta only allows free-form
replies within 24 hours of the user's last message. Reactive support fits this
naturally. Proactive messages outside the window need pre-approved templates,
which this channel does not send.</div>

### Switching models

`/model` and `/models` only fire on an `admin`-mode connection (see the mode
comparison in [Channels](../channels/)); on `support`, they are plain text like
any other slash command. `/models` lists the models available to this
connection's company; `/model` shows the one currently active, or changes it:

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
