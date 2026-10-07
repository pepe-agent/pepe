---
title: Slack
description: Put a Pepe agent in your Slack workspace so people can talk to it in channels and direct messages.
---

## Slack

Connecting Slack lets people talk to the agent right inside your workspace.
Slack delivers messages to Pepe through its Events API.

### Step by step

1. **Create the app.** At [api.slack.com/apps](https://api.slack.com/apps) →
   "Create New App" → pick **"Blank app"** (skip "AI agent" and the other
   templates - they come with Slack's own agent scaffolding, which you don't
   need here; Pepe is the agent). Pick your workspace.
2. **Grant the bot scopes.** Under **OAuth & Permissions → Scopes → Bot Token
   Scopes**, add `chat:write`, `app_mentions:read`, `channels:history` and
   `im:history`. Add `files:read` too if people will send pictures or files (without it the bot can't open them), `files:write` so the bot can send files back, `reactions:write` so it can mark the message it is working on with an eyes reaction, and `reactions:read` so a 👍 or ❤️ on one of its messages counts as feedback. For that last one also subscribe to the `reaction_added` bot event.
3. **Install the app.** Still on OAuth & Permissions, click "Install to
   Workspace" and copy the **Bot User OAuth Token** (`xoxb-...`).
4. **Grab the signing secret.** Under **Basic Information → App
   Credentials**, copy the **Signing Secret**.
5. **Register the connection in Pepe:**

   ```bash
   pepe setup
   ```

   Choose the channel option, pick Slack and the agent, and enter the
   credentials (a `${ENV_VAR}` reference is accepted for any secret). Pepe
   prints the callback URL to register:

   ```
   https://YOUR_HOST/webhooks/root/slack/<slug>
   ```

   Swap `YOUR_HOST` for wherever your server actually answers (a real domain
   in production; `mix pepe serve --tunnel` if you're just testing locally).
6. **Turn on events in Slack.** In the app → **Event Subscriptions** →
   Enable Events → paste the URL from the step above (Slack fires a
   `url_verification` handshake right away, and Pepe answers it on its own -
   no manual step needed). Under "Subscribe to bot events", add
   `message.channels`, `app_mention` and `message.im` (the last one is what
   makes a direct message actually work).
7. **Turn Socket Mode off.** New Slack apps often ship with it on by
   default: sidebar → **Socket Mode**. While it's on, Slack routes events
   over a WebSocket instead of hitting your Request URL - and Pepe only
   speaks the plain HTTP webhook, so nothing arrives, silently, even with
   everything else set up correctly. Leave it off.
8. **Save.** On the Event Subscriptions page, click "Save Changes" at the
   bottom before leaving - pasting the URL and navigating away without
   saving discards it.
9. If Slack asks, **reinstall the app** to the workspace (new scopes/events
   require it).
10. **Test it:** invite the bot to a channel (`/invite @your-bot`) and
    mention it, or send it a direct message.

### Connection fields

A connection's `config` holds:

- `bot_token`: the bot user OAuth token (`xoxb-...`), used as the bearer for
  replies.
- `signing_secret`: verifies the `X-Slack-Signature` on inbound requests.

Replies are posted with `chat.postMessage`.

See [Webhooks](../webhooks/) for the fields every connection shares (`agent`,
`mode`, `trainers`, `session_ttl_min`, `ephemeral`, `commands`) and how the
generic route works under the hood.

### Messages from other apps

A channel that gets its work from another system (a help desk posting each new ticket, a monitoring alert) receives messages written by an app, not by a person. Pepe ignores those by default, so the bot never answers itself or other bots. To answer one, list its bot id (`B...`) or app id (`A...`) in the connection's **Answer these bots and apps** field (`accept_bots`, comma separated). Each message Pepe ignores is logged with its ids, so you can copy the right one from the log instead of guessing. A listed app is answered **without being @mentioned**, so you do not need `/mention off` for that channel: people writing there still have to mention the bot, and only the app you listed gets through on its own.

Integrations often put the whole message in the coloured-bar attachment instead of the text. Pepe reads the attachment's title, body and fields as the message. The bot's own messages are never answered, even if its id is on the list.

To keep such a channel listening without an @mention, send `/mention off` once in it. It stays on after `/new` and after a restart, until someone sends `/mention on`.

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
