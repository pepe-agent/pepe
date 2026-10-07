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

Slack, Discord (in its gateway-connected mode, see [Discord](../discord/)), Microsoft Teams and Google Chat support group and channel conversations. There the bot answers only when it is @mentioned (a direct message always reaches the agent). A channel that should answer everything, such as one that receives tickets from another system, is told so from inside it:

```text
/mention off          # answer without a mention, until /new
/mention on           # require a mention again, until /new
/mention off always   # answer without a mention, kept across /new and restarts
/mention on always    # require a mention again, for good (the default)
/mention              # show what applies here
```

A plain `/mention off` or `/mention on` is for this conversation and is forgotten at `/new`. With `always` it is kept for the channel, whatever agent answers in it. What you said in the conversation beats what was kept for the channel, and `/new` hands the decision back to the channel. A setting never reaches another channel.

The rule has two levels, like every channel setting. The **connection** holds the default for all of its channels: *Answer without being mentioned* in the dashboard's connection form (`mention_optional` in the config, `pepe gateway mention SLUG --set optional|required` on the CLI), off unless you turn it on. A **channel** may hold its own answer, in either direction, and that one wins for that channel only: `/mention off always` opens a channel of a connection that requires mentions, `/mention on always` closes a channel of a connection that answers everything. When the channel's answer would merely repeat the connection's default, `/mention on always` just removes the channel's own setting. What applies, from the strongest down: this conversation (until `/new`), the channel's own setting, the connection's default, then a mention is required. `/mention` on its own says which of those is in force. Each channel's row on the Channels page shows the same thing, with an *own* or *from the connection* tag and a way back to the connection's; `pepe gateway mention SLUG --channel C --set optional|required` and `--default` do it from the CLI. The model cannot change any of it.

A channel that answers without a mention still stays out of a message written to someone else. In Slack, Discord, Microsoft Teams and Google Chat, a message that tags a person, a user group or the whole channel (`@here`, `@channel`) and does not tag the bot is for them, so the bot skips it; tagging the bot, alone or alongside others, brings it back. A message from another app is exempt, since a help desk's ticket card can name people and still be the agent's job.

Since a channel command still has to be addressed to run in the first place, the *first* `/mention off` needs an actual @mention (`@bot /mention off`). After that the channel no longer needs one. WhatsApp doesn't gate on mentions (it answers everything), so `/mention` is a no-op there.

Changing it is reserved for the channel's **trainers** (the same trusted list `/agent` uses), because it changes how the channel behaves for everyone in it. Anyone can still send `/mention` to see the current setting.

<div class="note"><strong>Typing a command in Slack.</strong> Slack's own
client treats anything starting with <code>/</code> as an attempt to run one
of its own slash commands, and refuses to send it as a message at all when
nothing is registered under that name - so <code>/mention off</code> typed
directly gets rejected by Slack before it ever reaches Pepe. Type a leading
space instead (<code> /mention off</code>) to send it as plain text; Pepe
strips it before matching the command, same as always.</div>

## Who can train a channel

`trainers` on the connection says who may turn a conversation into memory, and also who may change `/agent`, `/model ... global`, `/mention` and this very setting. It covers every channel of the connection. When one channel needs a different rule, give that channel its own list from inside it:

```text
/trainers                  # show who can train here, and where that comes from
/trainers *                # everyone in this channel
/trainers none             # no one
/trainers @ana @bruno      # only these people (a Slack tag or an id)
/trainers default          # back to the connection's list
```

A channel's own list is the stronger one: it **replaces** the connection's for that channel only, it is not added to it. Only someone who can train the channel now may change it, so nobody promotes themselves. It is kept across `/new` and restarts. The model cannot change it: it is a decision for a person, typed in the chat, from the dashboard (each connection's channel list, see below) or with `pepe gateway trainers SLUG --channel C --set ...`.

On Slack the trainers are the people (their user ids), because each message now says who wrote it. A list that named the channel id keeps working.

## Seeing where a connection lives

On the dashboard's Channels page, each connection card says how many channels, groups and direct messages it has heard from ("12 channels"). Open it to see them: the name when the platform gave one (otherwise the id), whether it is a group or a direct message, and when the last message came in. A channel is listed from the first message that arrives in it, whether or not the bot answered, so a channel the bot only listens in is there too.

Each row carries that channel's own settings, changed in place:

- **Agent**: the agent this channel is bound to, the same binding `/agent` sets in the chat, or the connection's until it has one.
- **Mention**: the channel's own answer to "does it need an @mention?", or the connection's default until it has one (see [Group @mentions](#group-mentions)). Only for providers that gate on mentions.
- **Who can train**: the channel's own trainers (see above), or the connection's until it has a list of its own.

Every setting is tagged *own* when the channel has its own value and *from the connection* when it inherits the default; *Use the connection's* removes only the channel's own value. A direct message is a channel too, listed and settable the same way.

Names come with the message on Microsoft Teams, Google Chat, WhatsApp (the contact's name) and Telegram (the group's title). On Slack the name is looked up once, the first time the channel is heard from, and needs the `channels:read` scope (`groups:read` for a private channel); without it the id is shown. Slack direct messages show their id.

A Telegram bot's card lists its groups, forum topics and private chats the same way, with the agent binding only: on Telegram, mentions and trainers are set per bot.

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

Set `agent_switch_locked: true` on the connection for a channel where nobody should
ever be able to change which agent answers - neither temporarily nor permanently. It
refuses `/agent NAME` outright, even for a trainer, plus `switch_agent` and
`manage_channel`'s `bind_topic`/`unbind_topic` for any conversation on that connection.
`/agent` with no arguments (status), `/mention`, `/model` and `/new` still work
normally. Set it with `--agent-switch-locked` on `mix pepe gateway whatsapp add` /
`discord add`, or directly in `config.json`.

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

## Approving risky tools in the chat

By default a webhook channel has nobody to ask, so a risky tool that is not in the agent's `auto_approve` is refused and held for an operator to approve from the command line (`mix pepe approvals`). To let the people in the conversation settle it instead, name the **trainers** on the connection: an explicit list, or `["*"]` for everyone in the conversation. Then, when the agent wants to do something risky, it asks right there, shows the actual command, and waits for a typed answer:

```text
Reply with: allow / allow all / allow session / deny
```

Only an exact reply from a trainer counts, and it is not passed on to the agent as a message. Anyone else's reply, or a longer sentence that happens to contain "allow", is just a message. The two widest answers ("allow everything for the session" and "always") cannot be typed here; use a surface with buttons for those. If nobody answers in five minutes it counts as a no, and the agent is told that nobody answered rather than that it was refused.

Without named trainers nothing changes: only what the agent has pre-approved runs.

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
