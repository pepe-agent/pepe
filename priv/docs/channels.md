# Channels — Telegram bots

Cortex talks to users over Telegram bots. You can run several bots at once, each
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
