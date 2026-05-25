---
title: Slack
description: Connect a Slack app to a Pepe agent over the Events API.
---

## Slack

Slack uses the Events API. Configure it through the guided setup (or the
dashboard), which asks for exactly the fields it needs and prints the callback
URL to register:

```bash
pepe setup
```

Choose the channel option, pick Slack and the agent, and enter the credentials
(a `${ENV_VAR}` reference is accepted for any secret). A connection's `config`
holds:

- `bot_token`: the bot user OAuth token (`xoxb-...`), used as the bearer for
  replies.
- `signing_secret`: verifies the `X-Slack-Signature` on inbound requests.

In the Slack app, set the Event Subscriptions request URL to the connection
URL and subscribe to `message.channels` and `app_mention`. The first save
triggers a `url_verification` handshake, which Pepe answers immediately.
Replies are posted with `chat.postMessage`. Callback URL shape:

```
https://YOUR_HOST/webhooks/default/slack/<slug>
```

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
