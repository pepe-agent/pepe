---
title: Telegram
description: Create and manage Telegram bots connected to Pepe agents.
---

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

### In groups

In a 1:1 chat the bot always replies. Added to a group, it only replies when
@mentioned or given a `/command`, by default - otherwise it would answer every
message in a busy group. Turn that requirement off entirely for a bot (every
group it's in) by setting `require_mention: false` during
`pepe gateway telegram setup`.

For a single group, without touching the bot's own setting, run:

```text
/mention off   # this group only, until /new - no @mention needed to be answered
/mention on    # back to requiring an @mention
/mention       # show the current setting
```

The waiver lives on that group's own conversation, not the bot, so it never
leaks into any other group the same bot is in, and a fresh conversation
(`/new`) forgets it.

A group conversation is one shared session across everyone in it, with no
per-sender labeling - if your agent needs to tell people apart, say so in its
prompt. The bot is also blind to anything not addressed to it: a message that
doesn't @mention it (and isn't waived by `/mention off`) never reaches the
agent at all, not even as silent context, so it can't "catch up" on chatter
that happened before it was brought in.

### Switch models mid-conversation

`/model` shows the model currently active in this chat, with a **Browse
models** button to pick a different one; `/models` jumps straight to that
picker. Typed usage:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this bot talks to
```

Anyone in an allowed conversation may switch their own session; changing it
**globally** (for every conversation this bot serves) is reserved for
**trainers** (the same allowlist that gates `/learn` and memory), so a random
chat member cannot silently repoint the whole bot at a different model. Set
`model_switch_locked: true` on the bot to turn model-switching off entirely for
non-trainers. A session override lives only in memory; it resets on `/new`
or a server restart, back to whatever the agent's own config says.

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
