---
title: Channels
description: Bind an agent to Telegram, WhatsApp, Slack, Discord, Microsoft Teams, Google Chat, or a generic inbound webhook, and people just chat with it.
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
2. The web dashboard (its "Channels" section lists your bots and connections,
   and walks you through adding one).
3. By chat. An agent that holds the right management tool can create and rebind
   Telegram bots, deliver files, and close a conversation, all in plain
   language. Those actions are guarded, so read the "Do it by chat" notes below
   for the exact confirmation step.

## Two shapes of channel

Channels differ only in how a message reaches Pepe:

- **Telegram** is a bot that Pepe polls. Nothing needs to be publicly
  reachable. Add a token, bind it to an agent, run the gateway.
- **Webhook channels** (WhatsApp, Slack, Discord, Microsoft Teams, Google Chat,
  and a generic inbound route) receive messages that the platform pushes to a
  callback URL. Pepe exposes one URL per connection. You register it with the
  provider once.

## Telegram

Telegram is the quickest channel to stand up because it needs no public URL.
Create a bot with @BotFather, copy its token, and register it.

Configure the default bot interactively:

```bash
pepe gateway telegram setup
```

This asks for the token (you can paste a literal token or a `${ENV_VAR}`
reference), an optional agent to bind, and an optional list of chat ids allowed
to talk to it.

You can run more than one bot, each bound to a different agent:

```bash
pepe gateway telegram add support --token "${SUPPORT_BOT_TOKEN}" --agent helpdesk --trainers none
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

The flags on `telegram add`:

- `--token` (required): the bot token, literal or `${ENV_VAR}`.
- `--agent`: which agent answers. Omit to use your default agent.
- `--trainers`: who this bot may learn from into memory. Omit for everyone,
  `none` for no one, or a comma-separated list of user ids for only those.
- `--heartbeat-minutes` and `--heartbeat-hours`: an optional periodic wake-up
  window (for agents that check things on a schedule). The hours are a local
  window like `8-22`.
- `--progress`: how the bot signals it is working while a run is in flight.
  One of `reaction` (a reaction on your message), `ambient` (one activity
  line), `off` (just the typing indicator), or `verbose` (a per-tool
  breakdown).

List and remove bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Run the poller in the foreground (one poller per bot):

```bash
pepe gateway telegram
```

You usually do not need to run that separately. `pepe serve` starts the
configured Telegram bots alongside the HTTP API, so a single running server
covers every channel at once.

<div class="note"><strong>Dashboard.</strong> The Channels section of the
dashboard lists your bots with a live active/inactive badge, lets you add a
bot, edit which agent it talks to, and remove it. It writes the same config the
CLI does.</div>

### Do it by chat

An agent that has the `manage_channel` tool can create and rebind Telegram bots
from a conversation. Because it edits config, every call goes through the
permission gate: the agent proposes the change and you confirm before it is
applied.

You would say:

> Add a Telegram bot named sales that talks to the sales agent. The token is in
> the SALES_BOT_TOKEN environment variable.

The agent calls `manage_channel` with `action: "add"`, `name: "sales"`,
`token_env: "SALES_BOT_TOKEN"`, and `agent: "sales"`. Two guardrails matter
here:

- **Secrets never pass through the chat.** You give the *name* of an
  environment variable that holds the token, never the token itself. It is
  stored as `${SALES_BOT_TOKEN}` and resolved at read time, so the raw secret
  never reaches the model or the logs. A raw token (which contains a colon) is
  rejected.
- **The protected default bot is off limits.** The tool only touches named
  bots, never the `default` one.

Other `manage_channel` actions are `list`, `set_agent` (rebind a bot to another
agent), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`, `disable`,
and `remove`. After any change it reconciles the running pollers, so a bot
starts or stops live without a restart.

<div class="note"><strong>Telegram only.</strong> The chat tool manages
Telegram bots. Webhook connections (WhatsApp, Slack, and the rest) are created
from the CLI, the dashboard, or <code>pepe setup</code>, not by chat.</div>

## How a webhook channel works

Every webhook channel, whatever the platform, is reachable at one route:

```
https://YOUR_HOST/webhooks/<company>/<provider>/<slug>
```

- `<company>` is the tenant scope. Use `root` for the default scope (shown as
  "Principal" in the dashboard), or a company handle to wall a connection off
  to that tenant.
- `<provider>` is the platform name: `whatsapp`, `slack`, `discord`,
  `msteams`, or `googlechat`.
- `<slug>` is the unique name you gave the connection.

A `GET` to that URL answers the provider's verification handshake (Pepe echoes
back the challenge the platform sends when you first register the URL). A `POST`
is an inbound event. On a `POST`, Pepe resolves the connection, verifies the
request signature against your configured secret, parses out the message, runs
the bound agent, and delivers the reply through the provider's own API. The
agent work runs in the background so the platform gets its acknowledgement
immediately (providers like Meta retry a slow webhook).

There is a single generic route. Adding a new provider never adds a new
endpoint.

<div class="note"><strong>Public host.</strong> Webhook channels need a URL the
platform can reach. Expose your Pepe instance behind a reverse proxy or a
tunnel, and set <code>PEPE_PUBLIC_URL</code> so the callback URLs the CLI prints
are complete. For a quick tunnel while testing, run <code>pepe serve
--tunnel</code>.</div>

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
| Slash commands | Treated as plain text | Enabled (for example `/new` resets) |

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

## WhatsApp

WhatsApp uses Meta's Cloud API. It has a dedicated CLI because it is the most
common webhook channel. Add a connection:

```bash
pepe gateway whatsapp add support \
  --agent helpdesk \
  --phone-number-id 123456789012345 \
  --mode support \
  --access-token '${WA_TOKEN}' \
  --app-secret '${WA_APP_SECRET}' \
  --verify-token my-verify-string
```

The connection's credentials (stored under its `config`):

- `phone_number_id`: the sending endpoint id from the Meta app.
- `access_token`: the Graph API bearer token. Store it as `${ENV_VAR}`.
- `app_secret`: verifies the inbound `X-Hub-Signature-256`. Store it as
  `${ENV_VAR}`.
- `verify_token`: any string you choose. Meta echoes it during the subscribe
  handshake. If you omit the flag, the slug is used.

If you leave `--access-token` or `--app-secret` off, the CLI writes a
placeholder reference derived from the slug (for example
`${WA_TOKEN_SUPPORT}`), so you can fill the real value into your environment
later. The command prints the callback URL and the verify token. Paste both
into the Meta app's webhook configuration:

```
https://YOUR_HOST/webhooks/root/whatsapp/support
```

Manage connections:

```bash
pepe gateway whatsapp list
pepe gateway whatsapp set-agent support billing
pepe gateway whatsapp remove support
```

The other flags on `whatsapp add` are `--company`, `--trainers`, `--ttl-min`,
`--ephemeral`, and `--commands`, mapping to the per-connection fields described
above. The dashboard adds and edits WhatsApp connections through the same
Channels section.

<div class="note"><strong>24-hour rule.</strong> Meta only allows free-form
replies within 24 hours of the user's last message. Reactive support fits this
naturally. Proactive messages outside the window need pre-approved templates,
which this channel does not send.</div>

## Slack, Discord, Microsoft Teams, Google Chat

These providers are configured through the guided setup (or the dashboard),
which asks for exactly the fields each one needs and prints the callback URL to
register:

```bash
pepe setup
```

Choose the channel option, pick the provider and the agent, and enter the
credentials (a `${ENV_VAR}` reference is accepted for any secret). Each
provider's required fields are below.

### Slack

Slack uses the Events API. A connection's `config` holds:

- `bot_token`: the bot user OAuth token (`xoxb-...`), used as the bearer for
  replies.
- `signing_secret`: verifies the `X-Slack-Signature` on inbound requests.

In the Slack app, set the Event Subscriptions request URL to the connection URL
and subscribe to `message.channels` and `app_mention`. The first save triggers
a `url_verification` handshake, which Pepe answers immediately. Replies are
posted with `chat.postMessage`. Callback URL shape:

```
https://YOUR_HOST/webhooks/root/slack/<slug>
```

### Discord

Discord is wired through the Interactions endpoint (slash commands), so it fits
the webhook gateway rather than a persistent connection. A connection's
`config` holds:

- `public_key`: the app's public key (hex), for the required Ed25519 signature
  check.
- `application_id`: used to post the follow-up answer.

In the Discord app, point "Interactions Endpoint URL" at the connection URL and
add a slash command with a text option (for example `/ask prompt:...`). Discord
requires an acknowledgement within three seconds, so Pepe replies with a
deferred response and posts the real answer as a follow-up once the agent
finishes.

### Microsoft Teams

Teams uses the Bot Framework. A connection's `config` holds:

- `app_id`: the bot's Microsoft app (client) id.
- `app_password`: the client secret. Store it as `${ENV_VAR}`.
- `tenant_id`: the Azure tenant id (or `botframework.com`).

Inbound activities arrive as `POST`s. Replies go back to the activity's service
URL with an app access token minted from the client credentials. The bot
mention is stripped from the incoming text before the agent sees it.

### Google Chat

Google Chat posts space events to the callback URL. A connection's `config`
holds:

- `access_token`: an OAuth token for the Chat API, used as the bearer for
  replies. Store it as `${ENV_VAR}` and refresh it out of band.

Only `MESSAGE` events from a human are acted on. Replies are posted back to the
space through the Chat REST API.

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

## Under the hood: the provider contract

Every webhook channel is one small module that implements the same contract, so
they all behave consistently and a new platform is a new module rather than a
new route. The callbacks are:

- `name` and `label`: the provider's URL segment and its human name.
- `config_schema`: the fields the dashboard renders to configure a connection.
- `verify`: answer the `GET` verification handshake.
- `authenticate`: verify the signature on an inbound `POST` against the
  connection's secret and the raw request body. A request that fails is
  dropped.
- `parse`: normalize the platform's payload into zero or more plain messages.
  Status updates and delivery receipts are ignored.
- `respond` (optional): produce a synchronous answer when the protocol demands
  one before any agent work, such as Slack's `url_verification` challenge or
  Discord's ping and deferred acknowledgement.
- `deliver`: send a text reply back to the sender.
- `deliver_file` (optional): send a file as an attachment.

If you write a plugin that implements this contract, it registers as a new
provider under its own `name`, reachable at the same `/webhooks/...` route with
no extra wiring.

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
</content>
</invoke>
