---
title: Google Chat
description: Put a Pepe agent in Google Chat so your team can talk to it in spaces and direct messages.
---

## Google Chat

Connecting Google Chat lets people talk to the agent in their spaces and
direct messages. Google Chat delivers each message to Pepe's callback URL;
configure the connection through the guided setup (or the dashboard):

```bash
pepe setup
```

A connection's `config` holds:

- `access_token`: an OAuth token for the Chat API, used as the bearer for
  replies. Store it as `${ENV_VAR}` and refresh it out of band.
- `project_number`: the Cloud project number the Chat app is registered
  under. In the Chat app's configuration page, set **Authentication
  Audience** to **Project Number**. The other option (HTTP endpoint URL)
  sends a token in a different format that Pepe doesn't verify, so every
  inbound message would be rejected.

Only `MESSAGE` events from a human are acted on. Replies are posted back to
the space through the Chat REST API. Callback URL shape:

```
https://YOUR_HOST/webhooks/default/googlechat/<slug>
```

### Inbound authentication

Pepe checks that every incoming request really comes from Google before the
agent sees anything: each request carries an `Authorization: Bearer`
Google-signed token, and Pepe validates it (signature against Google's
published keys, issuer, and an audience equal to `project_number`). So the
endpoint accepts `POST`s straight from Google, with no validating proxy
required. If your proxy already performs that check, set `trust_proxy: true`
on the connection to skip Pepe's.

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
