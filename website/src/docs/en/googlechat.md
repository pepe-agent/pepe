---
title: Google Chat
description: Connect a Google Chat app to a Pepe agent.
---

## Google Chat

Google Chat posts space events to the callback URL. Configure it through the
guided setup (or the dashboard):

```bash
pepe setup
```

A connection's `config` holds:

- `access_token`: an OAuth token for the Chat API, used as the bearer for
  replies. Store it as `${ENV_VAR}` and refresh it out of band.
- `project_number`: the Cloud project number the Chat app is registered
  under. In the Chat app's configuration page, set **Authentication
  Audience** to **Project Number** — the other option (HTTP endpoint URL)
  sends a differently-shaped token Pepe doesn't verify, and every inbound
  message would be rejected.

Only `MESSAGE` events from a human are acted on. Replies are posted back to
the space through the Chat REST API. Callback URL shape:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Inbound authentication

Each inbound request carries an `Authorization: Bearer` Google-signed token, and
Pepe validates it (signature against Google's published keys, issuer, and an
audience equal to `project_number`) before the agent sees anything. So the
endpoint accepts `POST`s straight from Google — no validating proxy required.
If your proxy already performs that check, set `trust_proxy: true` on the
connection to skip Pepe's.

See [Webhooks](../webhooks/) for the fields every connection shares (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) and how the
generic route works under the hood.

### Switching models

`/model` and `/models` only fire on an `admin`-mode connection with
`commands` enabled; on `support`, they are plain text. `/models` lists the
models available to this connection's project; `/model` shows the current
one, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Anyone in an allowed conversation may switch their own session; switching it
**globally** is reserved for **trainers**, the same allowlist that gates
memory. Set `model_switch_locked: true` on the connection to turn
model-switching off entirely for non-trainers.
