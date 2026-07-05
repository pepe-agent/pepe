---
title: Channels
description: Understand channel types, bindings, sessions, file delivery, and routing.
---

A channel connects one of your agents to a place where people already talk.
Someone sends a message, Pepe runs the bound agent (calling tools, reading the
reply back), and the answer is delivered on the same channel. You do not write
any glue code. You add a connection, point it at an agent, and it works.

Everything on this page assumes you already have at least one agent defined. If
you do not, see the agents guide first.

## Three ways to set this up

Like the rest of Pepe, channels can be managed three ways, and this page shows
each where it applies:

1. The `pepe` command line.
2. The dashboard (its "Channels" section lists your bots and connections,
   and walks you through adding one).
3. By chat. An agent that holds the right management tool can create and rebind
   Telegram bots, deliver files, and close a conversation, all in plain
   language. Those actions are guarded, so read the "Do it by chat" notes below
   for the exact confirmation step.

If you are coming from another agent runtime, `pepe migrate` imports its
existing channels instead of you adding each one by hand.

## Two shapes of channel

Channels differ only in how a message reaches Pepe:

- **Telegram** is a bot that Pepe polls. Nothing needs to be publicly
  reachable. Add a token, bind it to an agent, run the gateway.
- **Webhook channels** (WhatsApp, Slack, Discord, Microsoft Teams, Google Chat,
  and a generic inbound route) receive messages that the platform pushes to a
  callback URL. Pepe exposes one URL per connection. You register it with the
  provider once.

Every webhook channel, whatever the platform, is served by the same inbound
endpoint:

```
/webhooks/:project/:provider/:slug
```

`:project` is the tenant scope, and it is `default` when you are not using
extra projects. `:provider` is the platform name, and `:slug` is the name you gave the
connection. Adding a provider never adds a new endpoint.

These are the webhook channels that ship with Pepe, and what each one needs:

| Channel | How it connects | Config it needs |
|---|---|---|
| **WhatsApp** | Meta Cloud API webhook | `phone_number_id`, `access_token`, `app_secret`, `verify_token` |
| **Slack** | Events API webhook | `bot_token` (`xoxb-`), `signing_secret` |
| **Discord** | Interactions endpoint (slash commands) | `public_key`, `application_id` |
| **Microsoft Teams** | Bot Framework webhook | `app_id`, `app_password`, `tenant_id` |
| **Google Chat** | Chat API webhook | `access_token` (OAuth for the Chat API) |

Chatwoot is available too, as a channel [plugin](../plugins/) rather than a
built-in connection. It fronts WhatsApp, the web widget and more, and it brings
native human handoff. Channel plugins are configured on the dashboard's
**Integrations** tab rather than on **Channels**.

## Setup notes per channel

- **Slack.** Create an app, add a bot token scope, enable Event Subscriptions and
  point the request URL at the connection URL. Pepe answers the
  `url_verification` challenge itself. Add the `message.channels` and
  `app_mention` events. The signing secret verifies every request. See
  [Slack](../slack/).
- **Discord.** This uses the Interactions endpoint rather than a gateway bot, so
  it responds to **slash commands**. Add a command with a text option, then set
  the app's "Interactions Endpoint URL" to the connection URL. The app public key
  verifies the Ed25519 signature. The command is acknowledged immediately and the
  answer arrives as a follow-up. See [Discord](../discord/).
- **Microsoft Teams.** Register a bot in Azure and set its messaging endpoint to
  the connection URL. Pepe replies to the activity's `serviceUrl` with a token
  minted from the app credentials. The inbound Bot Framework JWT is validated, so
  the endpoint accepts POSTs straight from Microsoft. See
  [Microsoft Teams](../msteams/).
- **Google Chat.** Configure the app's webhook (HTTP) endpoint to the connection
  URL and provide an OAuth `access_token` for the Chat API. Replies are posted
  back to the space. Keep the endpoint behind a proxy. See
  [Google Chat](../googlechat/).

## Binding, sessions, and the two modes

Each connection (and each Telegram bot) names one `agent`. That is the binding.
Every distinct sender gets their own conversation, so context is retained per
person without you managing anything.

A webhook connection also has a `mode` that changes how the runtime behaves:

| | Support | Admin |
|--|---------|-------|
| Audience | Customer-facing, open to anyone | You, restricted to allowed senders |
| History | Ephemeral, each chat isolated | Kept across messages |
| Memory | Never learns | Conversations can become memory |
| Slash commands | Treated as plain text | Enabled (for example `/new` resets, `/model` switches models) |

Support is the safe default for anything the public can reach. Pair it with a
locked-down agent (safe tools only, since there is no human on your side to
approve a risky action) and, if you like, an idle session timeout. Admin is for
a channel only you use, where slash commands and memory are useful.

A few fields tune this per connection:

- `agent`: the agent this connection is bound to.
- `mode`: `support` or `admin`.
- `trainers`: who may turn a conversation into memory. `["*"]` is everyone,
  `[]` is no one, a list is only those senders, absent is the default (all).
- `session_ttl_min`: minutes of idle time before the conversation is dropped.
- `ephemeral`: when true, history is not carried between messages.
- `commands`: whether slash commands are honored (on by default in admin).

## What a connection looks like in config

There is no database. Connections live in `~/.pepe/config.json` under
`webhooks`, keyed by slug. Secrets are written as `${ENV_VAR}` and read back at
runtime, never expanded on disk. A Slack support connection looks like this:

```json
{
  "webhooks": {
    "support": {
      "provider": "slack",
      "agent": "helpdesk",
      "mode": "support",
      "config": {
        "bot_token": "${SLACK_BOT_TOKEN}",
        "signing_secret": "${SLACK_SIGNING_SECRET}"
      }
    }
  }
}
```

You can hand-edit this file, but the CLI and dashboard keep it valid for you.

## Sending files

An agent can hand a file back to whoever it is talking to. It produces the file
however it likes (for example a `bash` step that queries a database and writes
an `.xlsx`), then calls the `send_file` tool with the path:

```json
{
  "path": "/tmp/report.xlsx",
  "caption": "Here is this week's report."
}
```

Pepe figures out which channel the conversation is on and delivers the file
there. The agent never needs chat ids or tokens. Telegram sends it as a
document. WhatsApp, Slack, and Discord upload it as media on their APIs. If the
current channel cannot receive attachments (Microsoft Teams and Google Chat
send text only), the tool reports that back to the agent instead of failing
silently.

### Do it by chat

File delivery is itself a chat capability. Any agent with the `send_file` tool
does this the moment you ask. You would say:

> Pull last week's signups and send me the spreadsheet.

The agent runs whatever step builds the file, then calls `send_file` with the
resulting path. There is no separate confirmation gate on `send_file`; it only
delivers to the current conversation's own channel, resolved from the session,
so it cannot leak a file to anyone else.

## Ending a conversation

A support agent can close out its own conversation once an exchange is done, so
the next message from that person starts fresh. An agent with the `end_session`
tool does this by chat:

> Thanks, that is everything.

The agent sends its final reply first, then calls `end_session`, which clears
the live thread's context. Its learned knowledge is untouched. Only the current
conversation is reset. This is useful on a `support`-mode channel where each
exchange should be independent.

## Routing between agents

Beyond binding a channel to one agent, an agent that holds the `set_route` tool
can change which agents may message which, from chat. Routing is directed, so
allowing agent A to message agent B does not allow B to message A. Because it
edits config, it goes through the permission gate: you confirm the change
before it takes effect. You would say:

> Let the triage agent hand off to the billing agent.

The agent calls `set_route` with `to: "billing"` (and `from` defaults to the
one you are talking to), or `action: "deny"` to remove a route. On the command
line the same thing is `pepe agent route triage billing`.

## Not built in

Signal, IRC and iMessage need a persistent connection or a platform-specific
bridge that does not fit the webhook model, so they are out of scope for now. A
new channel can always be added as a channel [plugin](../plugins/).

## Serving it all

One command serves the OpenAI-compatible HTTP API, the WebSocket, the
dashboard, the webhook route, and every configured Telegram bot:

```bash
pepe serve --port 4000
```

The port also reads from the `PORT` environment variable. Add `--tunnel` to
open a public tunnel for testing webhook channels without your own reverse
proxy. Set `PEPE_PUBLIC_URL` so the callback URLs you register with each
provider point at your real host.
