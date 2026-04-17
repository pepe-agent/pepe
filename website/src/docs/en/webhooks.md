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
credentials (a `${ENV_VAR}` reference is accepted for any secret). Each has its
own page with its provider-specific fields and setup steps:
[Slack](../slack/), [Discord](../discord/), [Microsoft Teams](../msteams/),
[Google Chat](../googlechat/). This page covers what's shared by all of them
(and by WhatsApp).

## Switching models

`/model` and `/models` fire only on an `admin`-mode connection with `commands`
enabled (see the mode comparison in [Channels](../channels/)); on `support`,
they are plain text. `/models` lists the models available to the connection's
company; `/model` shows the current one, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Switching **globally** is reserved for **trainers** (the same allowlist that
gates memory); everyone else in an allowed conversation can only switch their
own session. Set `model_switch_locked: true` on the connection to turn it off
entirely for non-trainers. This is the same mechanism WhatsApp uses; Telegram's
version adds a tappable picker instead of typed commands.

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
