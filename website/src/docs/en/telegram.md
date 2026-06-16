---
title: Telegram
description: Create and manage Telegram bots connected to Pepe agents.
---

## Telegram

Telegram is the quickest channel to stand up because it needs no public URL.
Create a bot with @BotFather, copy its token, and register it. Pepe polls
Telegram for new messages, so there is no webhook to expose.

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
- `--trainers`: who this bot may learn from into memory, and who may run its
  operator commands. Omit for everyone, `none` for no one, or a comma-separated
  list of user ids for only those.
- `--heartbeat-minutes` and `--heartbeat-hours`: an optional periodic wake-up
  window (for agents that check things on a schedule). The hours are a local
  window like `8-22`. See "Heartbeat" below.
- `--progress`: how the bot signals it is working while a run is in flight.
  One of `reaction`, `ambient`, `off`, or `verbose`. See "Showing that it is
  working" below.

List and remove bots:

```bash
pepe gateway telegram list
pepe gateway telegram remove support
```

Run the poller in the foreground (one poller per bot):

```bash
pepe gateway telegram
```

Each bot gets its own poller, its own token, its own bound agent, its own
allowlists, and its own session namespace. Two bots that resolve to the same
token are de-duplicated, because two pollers on one token would conflict with
each other.

You usually do not need to run that separately. `pepe serve` starts the
configured Telegram bots alongside the HTTP API, so a single running server
covers every channel at once.

Within a single bot you can still switch the agent per chat with `/agent <name>`
(see [Routing](../routing/)). A dedicated bot is for when a whole channel should
*be* one agent.

<div class="note"><strong>Dashboard.</strong> The Channels section of the
dashboard lists your bots with a live active/inactive badge, lets you add a
bot, edit which agent it talks to, and remove it. It writes the same config the
CLI does, and the running pollers reconcile without a restart.</div>

### Where the config lives

The default bot lives under `"telegram"` in `~/.pepe/config.json`. Extra named
bots live under `"telegrams"`, a map of name to config, and each of them accepts
the same keys as the default one:

- `bot_token`: the token, literal or `${ENV_VAR}`.
- `enabled`: whether this bot's poller starts.
- `agent`: which agent answers.
- `allowed_chats` and `allowed_users`: the id allowlists. Leave them out and the
  bot talks to anyone.
- `require_mention`: in a group, only reply when the bot is @mentioned.
- `trainers`: who the bot learns from, and who may run its operator commands.

`/whoami` in a chat is the easy way to find the ids for those allowlists. It
prints your user id and the chat id.

Sessions are namespaced per bot. The default bot keys its conversations
`telegram:<chat_id>`, while a named bot uses `telegram:<name>:<chat_id>`. Two
bots therefore never collide, neither in their conversations nor in the delivery
of scheduled tasks.

### Slash commands

Every chat is a persistent session, driven with slash commands. They also appear
in Telegram's "/" menu, in your configured language.

| Command | What it does |
|---|---|
| `/new` | Start a fresh conversation |
| `/undo` | Undo your last message |
| `/retry` | Redo the last answer |
| `/compact` | Summarize the history to free up context |
| `/stop` | Stop the current run |
| `/inline <text>` | Feed a message into the run already in flight |
| `/btw <question>` | Ask a side question that is not saved to the conversation |
| `/mention on\|off` | In a group, require an @mention or not |
| `/model [name] [session\|global]` | Show the current model, or set it |
| `/learn` | Save what the agent learned into memory and skills |
| `/whoami` | Show your Telegram user and chat ids |
| `/help` | List the commands you can run |

And the operator commands, which only the bot's trainers can run:

| Command | What it does |
|---|---|
| `/agent <name>` | Switch the agent answering this chat |
| `/status` | Show session info |
| `/models` | Pick a model from a button list |
| `/tools` | List the runtime tools available |
| `/skill [name]` | List skills, or run one by name |
| `/approve` | Manage saved tool permissions |
| `/usage` | Show this month's spend and message count |

Installed skills become their own slash commands too, so a skill named `weather`
answers to `/weather` as well as to `/skill weather`, and it is discoverable from
the "/" menu. A skill command counts as an operator command, because a skill runs
arbitrary instructions through the agent.

#### Operator commands are trainers-only

The commands in the second table expose operator surface: your config, your
permissions, your spend, and the internal inventory of models, tools and skills.
They are gated to the bot's `trainers` allowlist, and the gate sits at the single
point where every command is dispatched, so a command that can be reached by two
names cannot slip around it.

- A bot with **no `trainers` list** trusts everyone it talks to. That is the
  personal bot, and nothing changes for it: you get every command, skills
  included.
- A bot **with a `trainers` list** is customer-facing. A client talking to it
  cannot reach `/approve`, `/agent`, `/status`, `/models`, `/tools`, `/skill` or
  `/usage`, nor any skill command. They are not advertised to that client either:
  `/help` lists only the commands the caller may actually run, and the bot's "/"
  menu is built for the least trusted person who can see it, so the operator
  commands are left out of the popup entirely. A non-trainer who types one anyway
  is told the command is not available here, and is never shown operator
  internals.

`/model` is deliberately half of each. Reading it (`/model` with no arguments)
reveals which model is behind the bot, which is infrastructure, so that path is
trainers-only. Switching is not: a client may pick a model for their own
conversation, unless you lock it. See "Switch models mid-conversation" below.

### In groups

In a 1:1 chat the bot always replies. Added to a group, it only replies when
@mentioned or given a `/command`, by default, since otherwise it would answer every
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
per-sender labeling. If your agent needs to tell people apart, say so in its
prompt. The bot is also blind to anything not addressed to it: a message that
doesn't @mention it (and isn't waived by `/mention off`) never reaches the
agent at all, not even as silent context, so it can't "catch up" on chatter
that happened before it was brought in.

### Forum topics

In a group that has **topics** turned on, each topic is its own conversation,
and a reply lands back in the topic it came from. You can give a topic **its own
agent**: run `/agent <name>` inside the topic and it stays bound to that agent,
kept across `/new` and restarts. So one group can have a "support" topic answered
by the support agent and an "engineering" topic by the engineer, side by side.
The agent for a message is the topic's bound agent if it has one, otherwise the
bot's `agent`, otherwise the global default. A bound topic still follows the
group's mention rule — set `require_mention: false` (or `/mention off` in that
topic) if you want it to answer without an @mention.

### Switch models mid-conversation

`/model` shows the model currently active in this chat, with a **Browse
models** button to pick a different one; `/models` jumps straight to that
picker. The picker is scoped to your project and puts a checkmark on the model
in use, so you tap one to switch. Both of those readings are trainers-only,
since they reveal which models sit behind the bot. Typed usage:

```text
/model openrouter               # ask whether to switch just this chat or everyone
/model openrouter session       # switch for this conversation only
/model openrouter global        # switch for everyone this bot talks to
```

Anyone in an allowed conversation may switch their own session; changing it
**globally** (for every conversation this bot serves) is reserved for
**trainers** (the same allowlist that gates `/learn` and memory), so a random
chat member cannot silently repoint the whole bot at a different model. A
trainer is the one asked which of the two they meant; anyone else just switches
their own conversation, with nothing to answer. Set `model_switch_locked: true`
on the bot to turn model-switching off entirely for non-trainers. A session
override lives only in memory; it resets on `/new` or a server restart, back to
whatever the agent's own config says.

### Showing that it is working

While a run is in flight the bot shows that it is busy. This is deliberately
ambient, not a status report you are meant to read. Telegram's native
"typing..." indicator stays alive in every mode. On top of it, `tool_progress`
(the `--progress` flag) picks one of four:

- `reaction`, the default: a 👀 reaction on your own message while the agent
  works, cleared when the answer lands. It adds no message to the chat, and it
  is the quietest of the four.
- `ambient`: a single vague line ("looking things up...", "running
  something...") edited in place and deleted when the answer arrives. No tool
  names, no arguments, no ledger.
- `off`: nothing but the native typing indicator.
- `verbose`: the full ledger, for power users who want to watch the run. Each
  tool call as it happens, and above it the sentence the model said before
  reaching for that tool. The ledger tells you *what* it did; the sentence tells
  you *why*, which is what lets you see it heading somewhere wrong before it
  gets there. Still one message, edited in place, deleted when the answer lands.

Set it three ways: from the command line with `--progress`; from a chat with the
`manage_channel` tool (`set_progress`); or in the **dashboard** under Channels →
your bot → *Edit* → "While the agent works", where each mode is spelled out.

### Heartbeat: proactive check-ins

A bot can periodically give its agent the floor to say something **on its own
initiative** ("the deploy finished", "you asked me to watch for X") and, just as
importantly, the right to say **nothing** most of the time. It is off by default,
and you opt in per bot:

```bash
pepe gateway telegram add ops --token "${OPS_BOT_TOKEN}" --agent operator --heartbeat-minutes 30 --heartbeat-hours 8-22
```

An agent that holds the `manage_channel` tool can also set this up itself, from
a chat:

```text
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Each pulse runs the agent on its session's live context, with a prompt that says
this is an automatic check and to reply with exactly `HEARTBEAT_OK` if there is
nothing worth saying. That is the common case, and only a genuine message is ever
sent to the chat. You feed it two things:

- An optional `HEARTBEAT.md` in the agent's workspace, which is where you write
  what to watch for.
- **System events**, which any part of Pepe can queue for a session
  (`Pepe.Heartbeat.Events.push/2`), and which the next pulse picks up
  automatically.

A runaway proactive loop is impossible by construction. A cooldown gate enforces
a 30 second minimum between pulses, and a flood breaker trips at 5 fires in 60
seconds. `heartbeat_hours` (a local window like `8-22`) keeps the bot quiet
outside waking hours.

### Dead chats heal themselves

If a send comes back permanently failed, because the bot was blocked or the chat
or user is gone, that chat is skipped on every further send. There are no wasted
API calls and no log noise. The moment a send to it succeeds again, for instance
because the user unblocked the bot, the chat is un-marked automatically. There is
nothing to reset by hand.

### Language and errors

Pepe's own fixed messages (command replies, buttons, refusals) follow the
`locale` you configured. The agent's replies follow the language the user writes
in, whatever that is. Raw internal errors are never leaked into the chat.

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
  rejected. You set that environment variable yourself.
- **The protected default bot is off limits.** The tool only touches named
  bots, never the `default` one, and it touches nothing else in your config.

Other `manage_channel` actions are `list`, `set_agent` (rebind a bot to another
agent), `set_trainers`, `set_heartbeat`, `set_progress`, `enable`, `disable`,
and `remove`. After any change it reconciles the running pollers, so a bot
starts or stops live without a restart.

<div class="note"><strong>Telegram only.</strong> The chat tool manages
Telegram bots. Webhook connections (WhatsApp, Slack, and the rest) are created
from the CLI, the dashboard, or <code>pepe setup</code>, not by chat.</div>
