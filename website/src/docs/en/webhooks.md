---
title: Webhooks
description: Configure Slack, Discord, Microsoft Teams, Google Chat, and generic webhook channels.
---

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
