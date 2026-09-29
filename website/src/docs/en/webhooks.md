---
title: Webhooks
description: Configure Slack, Discord, Microsoft Teams, Google Chat, and generic webhook channels.
---

## How a webhook channel works

Every webhook channel, whatever the platform, is reachable at one route:

```
https://YOUR_HOST/webhooks/<project>/<provider>/<slug>
```

- `<project>` is the project the connection belongs to. Use `default` for the
  default project, or another project's slug to keep that connection isolated
  to its own project.
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
tunnel. If <code>PHX_HOST</code> is already set (see <a href="../deploy/">Deploying</a>),
the callback URLs the CLI and dashboard print already use it; set
<code>PEPE_PUBLIC_URL</code> to override that or fill it in when it isn't. For a
quick tunnel while testing, run <code>pepe serve --tunnel</code>.</div>

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

## Group @mentions

Slack, Discord (in its gateway-connected mode, see [Discord](../discord/)),
Microsoft Teams and Google Chat support group/channel conversations, where
the connection answers only when @mentioned by default (a direct message
always reaches the agent regardless). Set `require_mention: false` on the
connection to answer every message in every channel it's in. Or, without
touching that connection-wide setting, waive it for a single channel from
inside that channel:

```text
/mention off   # this channel only, until /new - no @mention needed to be answered
/mention on    # back to requiring an @mention
/mention       # show the current setting
```

Since a channel command still has to be addressed to run in the first place,
the *first* `/mention off` needs an actual @mention (`@bot /mention off`);
after that, the channel no longer needs one until `/new`. The waiver lives on
that channel's own conversation, not the connection, so it never leaks into
any other channel. WhatsApp doesn't gate on mentions today (always
answered), so `/mention` is a no-op there.

<div class="note"><strong>Typing a command in Slack.</strong> Slack's own
client treats anything starting with <code>/</code> as an attempt to run one
of its own slash commands, and refuses to send it as a message at all when
nothing is registered under that name - so <code>/mention off</code> typed
directly gets rejected by Slack before it ever reaches Pepe. Type a leading
space instead (<code> /mention off</code>) to send it as plain text; Pepe
strips it before matching the command, same as always.</div>

## Binding a channel to an agent

`/agent NAME` durably binds THIS conversation to an agent - a group can route its
"support" channel to the support agent and its "engineering" channel to the engineer,
side by side, the same way a Telegram forum topic already can (see
[Telegram](../telegram/)). Kept across `/new` and restarts, and reasserted every turn,
so it always wins over anything the conversation drifted to in the meantime:

```text
/agent engenheiro   # bind this channel, from now on
/agent              # show the current binding
/agent none         # unbind, back to the connection's own default agent
```

This is a lasting, channel-wide decision, not a one-off routing choice, so it's
reserved for **trainers** (the same trusted list `/model ... global` already uses) -
anyone else gets a plain "you don't have permission" instead. An agent with the
`manage_channel` tool can do the same thing from plain language ("connect this channel
to the engineer, permanently") with its `bind_topic`/`unbind_topic` actions - see
[Agent-to-agent routing](../routing/) for the difference between this and
`switch_agent`, which is deliberately temporary and undone by `/new`.

## Switching models

The `/model` and `/models` commands let people check or change which AI model
answers them. They work only on an `admin`-mode connection with `commands`
enabled (see the mode comparison in [Channels](../channels/)); on `support`,
they are treated as plain text. `/models` lists the models available to the
connection's project; `/model` shows the current one, or changes it:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this connection talks to
```

Switching **globally**, for everyone the connection talks to, is reserved for
**trainers** (the same trusted list that controls memory); everyone else in an
allowed conversation can only switch their own conversation. Set
`model_switch_locked: true` on the connection to turn it off entirely for
non-trainers. This is the same mechanism WhatsApp uses; Telegram's version
adds a tappable picker instead of typed commands.

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
