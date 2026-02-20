# Channels — Telegram bots

Pepe talks to users over Telegram bots. You can run several bots at once, each
bound to one agent. Manage them with the `manage_channel` tool.

## Add / manage a bot (`manage_channel`)

- `add name: "sales" token_env: "SALES_BOT_TOKEN" agent: "sales-bot"` — a new bot.
  **`token_env` is the NAME of an environment variable** holding the @BotFather
  token, not the token itself — it's stored as `${SALES_BOT_TOKEN}`, so the secret
  never reaches the chat or config. Ask the user to set that env var.
- `list` — configured bots.
- `set_agent name: X agent: Y` — rebind bot X to agent Y.
- `enable` / `disable` / `remove name: X`.

Guard-rails: the tool only touches **named** bots, never the protected `default` bot
or any other config; a raw token (not an env-var name) is refused. Changes reconcile
the running pollers live.

## One bot = one channel = one agent

Each bot is a whole channel bound to its agent. Use dedicated bots when a channel
should *be* one agent. Within a single bot, `/agent <name>` switches agent per chat.

## Who the bot learns from (`trainers`)

Learning (turning conversations into memory/skills) is gated per bot by a `trainers`
allowlist of user ids:

- **`["*"]`** → learns from everyone. **`[]`** → learns from no one (a client-facing
  bot). **`[id1, id2]`** → learns only from those users. **omitted** → default
  (everyone).

So a client-facing bot (`trainers: []`) never lets a client's chat become the agent's
memory, while your own DM bot still learns from you.

## Heartbeat — proactive check-ins (opt-in)

A bot can periodically give its agent the floor to say something **on its own
initiative** — "the deploy finished", "you asked me to watch for X and it happened"
— and, just as importantly, the right to say **nothing** most of the time. Off by
default. Enable with `manage_channel`:

```
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

- `heartbeat_minutes` — how often to check (0 disables it).
- `heartbeat_hours` — local-hour window ("8-22"); outside it, no pulse. Omit for
  always-on.

Each pulse runs on the session's live context. Add an optional `HEARTBEAT.md` to the
agent's workspace describing what to watch for; system events (queued by any
subsystem via `Pepe.Heartbeat.Events`) are included automatically. The agent
replies with exactly `HEARTBEAT_OK` when there's nothing worth saying — that's
expected most of the time and nothing is sent. A cooldown gate (min 30s spacing, a
flood breaker at 5 fires/60s) makes a runaway proactive loop impossible.
