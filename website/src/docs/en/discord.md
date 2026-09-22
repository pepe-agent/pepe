---
title: Discord
description: Answer slash commands, or ordinary channel messages, in your Discord server with a Pepe agent.
---

## Discord

Discord gives Pepe two different ways to receive a message, and a connection
can use either or both:

- A **slash command** (for example `/ask`), delivered over Discord's
  Interactions endpoint. This fits Pepe's webhook gateway the same way every
  other provider does: no process to keep running, Discord calls your server.
- An **ordinary message** typed into a channel, a DM, or a reply, delivered
  over Discord's gateway - a WebSocket the bot holds open. This needs an
  opt-in and a bot token (below), because it is a persistent connection
  rather than a webhook call.

Start with the guided setup (or the dashboard):

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

This is the only route a file has through the Interactions endpoint - it sees slash commands and nothing else, so a voice message or an attachment posted straight into a channel does not reach Pepe this way. It does reach Pepe the other way, over the gateway: see **Ordinary channel messages** below. Pepe accepts files up to 20 MB by default (`max_attachment_mb` on the connection can raise or lower that), and whichever of Pepe's limit and Discord's own upload limit is smaller wins: Discord's own upload limit is 10 MB on a plain account or an unboosted server, higher with Nitro or a boosted server. See [Voice messages](../voice/) and [Documents](../documents/).

### Ordinary channel messages

A connection can also answer a message typed straight into a channel, a photo dropped into it, a voice message recorded in it, or a direct message to the bot - not just a slash command. This needs its own opt-in, because it means Pepe holds a persistent connection to Discord's gateway rather than only answering webhook calls:

```bash
pepe gateway discord add support --agent helpdesk --gateway --bot-token '${DISCORD_BOT_TOKEN}'
```

or the equivalent fields in the dashboard (a connection can have both `--application-id`/`--public-key` for slash commands and `--gateway`/`--bot-token` for channel messages at once). `mix pepe serve` runs the connection either way. Flags:

- `--gateway`: turns this on.
- `--bot-token '${ENV}'`: the bot's token from the Discord Developer Portal, stored as `${ENV_VAR}`. Turn on the **Message Content** intent on the app's Bot page too, or Discord will not deliver the text of a message that does not @mention the bot.
- `--no-require-mention`: in a server, the bot only answers a message that @mentions it or replies to something it said, by default. Pass this to answer every message in a channel it can see instead. In a direct message, the bot always answers, regardless of this flag.
- `--max-attachment-mb N`: raise or lower the 20 MB default cap for this connection.

Attachments of the message itself, of the message it replies to (so a voice note can be answered "what does this say?" after the fact), and of a message forwarded to the bot all count, and go through the same voice-to-transcript, document-to-text, image-to-vision handling as a slash command's attachment. Messages on one connection are answered in the order Discord delivered them. If the connection drops, it reconnects and resumes automatically, with nothing said in the gap lost.

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
