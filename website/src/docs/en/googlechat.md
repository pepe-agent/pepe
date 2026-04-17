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

Only `MESSAGE` events from a human are acted on. Replies are posted back to
the space through the Chat REST API. Callback URL shape:

```
https://YOUR_HOST/webhooks/root/googlechat/<slug>
```

See [Webhooks](../webhooks/) for the fields every connection shares (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) and how the
generic route works under the hood.

### Switching models

`/model` and `/models` only fire on an `admin`-mode connection with
`commands` enabled; on `support`, they are plain text. `/models` lists the
models available to this connection's company; `/model` shows the current
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
