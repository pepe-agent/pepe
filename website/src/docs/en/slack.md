---
title: Slack
description: Put a Pepe agent in your Slack workspace so people can talk to it in channels and direct messages.
---

## Slack

Connecting Slack lets people talk to the agent right inside your workspace.
Slack delivers messages to Pepe through its Events API; configure the
connection through the guided setup (or the dashboard), which asks for exactly
the fields it needs and prints the callback URL to register:

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

The `/model` and `/models` commands let people check or change which AI model
answers them. They work only on an `admin`-mode connection with `commands`
enabled; on `support`, they are treated as plain text. `/models` lists the
models available to this connection's project; `/model` shows the current
one, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Anyone in an allowed conversation may switch the model for their own
conversation. Switching it **globally**, for everyone this connection talks
to, is reserved for **trainers**, the same trusted list that controls memory.
Set `model_switch_locked: true` on the connection to turn model-switching off
entirely for non-trainers.
