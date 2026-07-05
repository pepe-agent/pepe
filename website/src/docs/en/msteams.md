---
title: Microsoft Teams
description: Connect a Microsoft Teams bot to a Pepe agent over the Bot Framework.
---

## Microsoft Teams

Teams uses the Bot Framework. Configure it through the guided setup (or the
dashboard):

```bash
pepe setup
```

A connection's `config` holds:

- `app_id`: the bot's Microsoft app (client) id.
- `app_password`: the client secret. Store it as `${ENV_VAR}`.
- `tenant_id`: the Azure tenant id (or `botframework.com`).

Inbound activities arrive as `POST`s. Replies go back to the activity's
service URL with an app access token minted from the client credentials. The
bot mention is stripped from the incoming text before the agent sees it.
Callback URL shape:

```
https://YOUR_HOST/webhooks/default/msteams/<slug>
```

### Inbound authentication

Each inbound request carries an `Authorization: Bearer` Bot Framework token, and
Pepe validates it (signature against Microsoft's published keys, issuer, and an
audience equal to the bot's `app_id`) before the agent sees anything. So the
endpoint accepts `POST`s straight from Microsoft — no validating proxy required.
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
