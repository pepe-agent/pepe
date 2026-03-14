# Telegram

Configure interactively (creates a bot via [@BotFather](https://t.me/BotFather)
first), then run the long-polling gateway (no webhook needed):

```bash
mix pepe gateway telegram setup      # bot token, allowlists, which agent answers
mix pepe gateway telegram            # run it
```

Each chat is a persistent session. In-chat slash commands (also shown in the "/"
menu, in your configured language):

```
/new        start a fresh conversation        /status   show session info
/undo       undo your last message            /whoami   show your user/chat id
/compact    summarize history to free context /model    show or set the model
/stop       cancel the current run            /models   list configured models
/agent X    switch agent                      /tools    list runtime tools
/skill [X]  list skills, or run one by name   /approve  manage saved permissions
/btw <q>    ask a side question (not saved)    /help     list commands
```

Installed **skills are also surfaced as their own slash commands** (e.g. a
`weather` skill shows up as `/weather`), so they're discoverable from the "/" menu.

`/whoami` is the easy way to find the ids for the allowlists. Config keys under
`"telegram"`: `bot_token`, `enabled`, `allowed_chats`, `allowed_users`,
`require_mention` (only reply when @mentioned in groups), `agent`. Fixed system
messages follow the configured `locale`; the agent's own replies follow the user's
language, and raw internal errors are never leaked into the chat.

A **dead chat is self-healing**: if a send comes back permanently failed (bot
blocked, chat/user gone), that chat is skipped on every further send - no wasted API
calls or log noise - and automatically un-marked the moment a send to it succeeds
again (e.g. the user un-blocked the bot). No manual reset needed.

**"Working" activity while the agent runs** is deliberately ambient, not a status
report you're meant to read. Tune it per bot with `tool_progress`:

- `reaction` (default) - a 👀 reaction on your own message while the agent works,
  cleared when the answer lands. No extra message in the chat; the quietest signal.

- `ambient` - a single vague line ("🔎 looking things up...", "💻 running something...")
  edited in place and deleted when done. No tool names, args or ledger.

- `off` - nothing but the native "typing..." indicator.

- `verbose` - a per-tool breadcrumb list (for power users).

The native "typing..." indicator stays alive across all modes. Set it from chat
(`manage_channel` -> `set_progress`) or the CLI (`--progress`).

### Heartbeat - proactive check-ins (opt-in)

A bot can periodically give its agent the floor to say something **on its own
initiative** ("the deploy finished", "you asked me to watch for X") - and, just as
importantly, the right to say **nothing** most of the time. Off by default:

```bash
# via the manage_channel tool (an agent can set this up itself, from chat):
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Each pulse runs the agent on its session's live context with a prompt that says
"this is an automatic check - reply with exactly `HEARTBEAT_OK` if there's nothing
worth saying." That's the common case; only a genuine message gets sent. Feed it:

- an optional `HEARTBEAT.md` in the agent's workspace ("what to watch for"),

- **system events** any part of Pepe can queue for a session
  (`Pepe.Heartbeat.Events.push/2`) and the next pulse picks up automatically.

A cooldown gate (30s min spacing, a 5-fires/60s flood breaker) makes a runaway
proactive loop impossible, and `heartbeat_hours` ("8-22") keeps it quiet outside
local waking hours.

### Multiple bots, one per agent

You can run **several bots at once, each bound directly to its own agent** - one
Telegram bot *is* agent X, another *is* agent Y. Pepe starts one poller per bot;
each has its own token, bound agent, allowlists and session namespace.

```bash
mix pepe gateway telegram setup                        # the default bot
mix pepe gateway telegram add sales --token $T --agent sales-bot
mix pepe gateway telegram add ops   --token $T2 --agent ops-bot
mix pepe gateway telegram list                         # see them all
mix pepe gateway telegram                              # runs every bot
```

The default bot lives under `"telegram"`; extra bots under `"telegrams"` (a
name->config map) in `~/.pepe/config.json`, each accepting the same keys. Bots
that resolve to the same token are de-duplicated (two pollers on one token would
conflict). The default bot keeps the `telegram:<chat_id>` session key; named bots
use `telegram:<name>:<chat_id>`, so their conversations (and cron delivery) never
collide. You can also manage bots live from the **Bots** tab in the dashboard -
add/remove there and the running pollers reconcile without a restart.

Within a single bot you can still switch agent per chat with `/agent X` (see
**Agent-to-agent routing**); dedicated bots are for when a whole channel should
*be* one agent.

#### Let an agent add a bot from chat

An agent can create and manage bots itself with the `manage_channel` tool - *"add
a bot for the sales agent, token in `$SALES_BOT_TOKEN`"* - as long as the tool is in
its allowlist. It's guarded two ways:

- **Permission gate** - `manage_channel` is a risky tool, so each call is authorized
  by the human (or pre-approved), like any risky tool.

- **Scoped** - it only touches named bots, never the protected `default` bot or any
  other config.

- **Secrets never pass through the chat** - you give the *name of an environment
  variable* holding the token (`token_env: "SALES_BOT_TOKEN"`), not the token; it's
  stored as `${SALES_BOT_TOKEN}` and resolved at read time, so the raw secret never
  reaches the model or the logs. Set that env var yourself.

After a change the running pollers reconcile live. Actions: `add`, `list`,
`set_agent`, `enable`, `disable`, `remove`.

---

[Back to the docs index](../README.md#documentation)
