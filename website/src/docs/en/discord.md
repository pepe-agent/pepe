---
title: Discord
description: Wire a Discord app's Interactions endpoint to a Pepe agent.
---

## Discord

Discord is wired through the Interactions endpoint (slash commands), so it
fits the webhook gateway rather than a persistent connection. Configure it
through the guided setup (or the dashboard):

```bash
pepe setup
```

A connection's `config` holds:

- `public_key`: the app's public key (hex), for the required Ed25519
  signature check.
- `application_id`: used to post the follow-up answer.

In the Discord app, point "Interactions Endpoint URL" at the connection URL
and add a slash command with a text option (for example `/ask prompt:...`).
Discord requires an acknowledgement within three seconds, so Pepe replies
with a deferred response and posts the real answer as a follow-up once the
agent finishes. Callback URL shape:

```
https://YOUR_HOST/webhooks/default/discord/<slug>
```

See [Webhooks](../webhooks/) for the fields every connection shares (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) and how the
generic route works under the hood.

### Switching models

Your registered command (`/ask` above) carries whatever text you put in its
`prompt:` option, so `/model` and `/models` reach Pepe the same way any other
message would, typed as that value. They only fire on an `admin`-mode
connection with `commands` enabled; on `support`, they are plain text.
`/models` lists the models available to this connection's project; `/model`
shows the current one, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Anyone in an allowed conversation may switch their own session; switching it
**globally** is reserved for **trainers**, the same allowlist that gates
memory. Set `model_switch_locked: true` on the connection to turn
model-switching off entirely for non-trainers.
