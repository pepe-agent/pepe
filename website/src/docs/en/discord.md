---
title: Discord
description: Answer slash commands in your Discord server with a Pepe agent.
---

## Discord

On Discord, people talk to the agent through a slash command (for example
`/ask`). Discord delivers those commands over its Interactions endpoint, which
fits Pepe's webhook gateway rather than a persistent connection. Configure it
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

### Files on a command

Give a slash command an **attachment option** and people can send Pepe a file with it: `/ask prompt:what does he say? file:<clip>`. A voice clip is transcribed before the agent runs, a document arrives with its text, and an image reaches a vision model as an image. The attachment is enough on its own, so `/ask file:<clip>` with nothing typed still works.

This is the only route a file has here. An interactions endpoint sees slash commands and nothing else, so a voice message or an attachment posted straight into a channel never reaches Pepe. Discord's own upload limit applies (10 MB on an unboosted server). See [Voice messages](../voice/) and [Documents](../documents/).

### Switching models

The `/model` and `/models` commands let people check or change which AI model
answers them. On Discord they reach Pepe through your registered command
(`/ask` above): whatever you type in its `prompt:` option is the message Pepe
sees. They work only on an `admin`-mode connection with `commands` enabled;
on `support`, they are treated as plain text. `/models` lists the models
available to this connection's project; `/model` shows the current one, or
changes it:

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
