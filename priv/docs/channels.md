# Channels - Telegram bots

Pepe talks to users over Telegram bots. You can run several bots at once, each
bound to one agent. Manage them with the `manage_channel` tool.

## Add / manage a bot (`manage_channel`)

- `add name: "sales" token_env: "SALES_BOT_TOKEN" agent: "sales-bot"` - a new bot.
  **`token_env` is the NAME of an environment variable** holding the @BotFather
  token, not the token itself - it's stored as `${SALES_BOT_TOKEN}`, so the secret
  never reaches the chat or config. Ask the user to set that env var.
- `list` - configured bots.
- `set_agent name: X agent: Y` - rebind bot X to agent Y.
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

- **`["*"]`** -> learns from everyone. **`[]`** -> learns from no one (a client-facing
  bot). **`[id1, id2]`** -> learns only from those users. **omitted** -> default
  (everyone).

So a client-facing bot (`trainers: []`) never lets a client's chat become the agent's
memory, while your own DM bot still learns from you.

## Heartbeat - proactive check-ins (opt-in)

A bot can periodically give its agent the floor to say something **on its own
initiative** - "the deploy finished", "you asked me to watch for X and it happened"
- and, just as importantly, the right to say **nothing** most of the time. Off by
default. Enable with `manage_channel`:

```
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

- `heartbeat_minutes` - how often to check (0 disables it).
- `heartbeat_hours` - local-hour window ("8-22"); outside it, no pulse. Omit for
  always-on.

Each pulse runs on the session's live context. Add an optional `HEARTBEAT.md` to the
agent's workspace describing what to watch for; system events (queued by any
subsystem via `Pepe.Heartbeat.Events`) are included automatically. The agent
replies with exactly `HEARTBEAT_OK` when there's nothing worth saying - that's
expected most of the time and nothing is sent. A cooldown gate (min 30s spacing, a
flood breaker at 5 fires/60s) makes a runaway proactive loop impossible.

## In-chat slash commands (Telegram)

Inside a Telegram chat the user drives the session with slash commands - they don't
reach you as prompts, the gateway handles them. Know they exist so you can point a
user at the right one instead of trying to do it yourself:

- `/new` - start a fresh conversation (clears context). `/undo` - drop the last
  message. `/compact` - summarize history to reclaim context.
- `/agent <name>` - switch which agent this chat talks to. `/model <name>
  [session|global]` / `/models` - show or change the model (a trainer may set it
  globally, others only for their own conversation). `/tools` - list runtime tools.
- `/skill <name>` - list or run a skill. `/btw <question>` - ask a one-off side
  question that isn't saved to history. `/learn` - save what was learned to
  memory/skills. `/approve` - inspect or clear the "always allow" tool grants.
- `/status` - session info. `/whoami` - the user's Telegram user and chat ids (this
  is how they find the ids for `allowed_users` / `trainers`). `/stop` - cancel the
  current run. `/help` - the full list. Installed skills also appear as their own
  `/`-commands.

## Working-activity display (`tool_progress`)

Per Telegram bot, you can tune how much of your tool activity the user sees while you
work. Set it with `manage_channel`:

```
manage_channel set_progress name: "sales" mode: "ambient"
```

- `reaction` - **the default.** No status message at all; just a 👀 reaction on the
  user's own message while working, cleared when the answer lands. The quietest.
- `ambient` - one vague "what kind of work is happening" line (e.g. "🔎 looking
  things up..."), edited in place - no tool names, args or per-step ledger.
- `off` - nothing but the native typing indicator.
- `verbose` - a detailed per-tool breadcrumb list, for power users.

The message-based modes (`ambient`/`verbose`) use a single message that's edited as
tools run and deleted when the turn ends, so only the final answer stays in the chat.

## WhatsApp (Meta Cloud API)

WhatsApp connects over a webhook, not polling. Each connection has its own URL -
`/webhooks/<project>/whatsapp/<slug>` (project is `default` when none is named) - served
by `mix pepe serve`. Add one from chat with the CLI or the dashboard Channels tab:

    mix pepe gateway whatsapp add support --agent acme/support --project acme \
      --mode support --phone-number-id 123 --ttl-min 30

A connection binds to an agent (like a Telegram bot) and has a `mode`: `admin`
(slash commands on, restricted to your `allowed_numbers`, learns from you) or
`support` (commands off, open to anyone, `trainers: []` so it never learns from a
customer, ephemeral sessions). A support agent should have a locked-down tool
allowlist - there is no human to approve risky tools on a customer chat.

Sessions are keyed `whatsapp:<agent>:<phone>`. The agent ends a conversation with the
`end_session` tool (clears the context for the next message); an idle TTL
(`--ttl-min`) also evicts quiet sessions. To hand off to a specialist, the agent
uses `send_to_agent` - no special routing in the webhook layer.

Tokens are `${ENV_VAR}` refs (`access_token`, `app_secret`). Note Meta's 24-hour
rule: free-form replies only within 24h of the customer's last message.

## Other webhook channels

Slack, Discord, Microsoft Teams and Google Chat are all inbound-webhook channels
like WhatsApp - each is a connection at `/webhooks/<project>/<provider>/<slug>`
served by `mix pepe serve`, binding an agent to a session keyed
`<provider>:<agent>:<from>`, with the same `admin` / `support` modes. Unlike Telegram
(`manage_channel`) and WhatsApp (`mix pepe gateway whatsapp add`), these four have no
agent tool or CLI to set them up - a human configures them on the dashboard
Integrations tab (which shows the URL to paste into the platform). If a user asks you
to "add a Slack channel", point them there rather than reaching for a tool. All
secrets below are `${ENV_VAR}` refs, resolved at read time, never stored expanded.

### Slack (Events API)

Config: `bot_token` (the `xoxb-...` bot user token, the Bearer for replies) and
`signing_secret` (verifies the `X-Slack-Signature` on each inbound POST). Point the
Slack app's Event Subscriptions request URL at the connection URL - the first save
triggers a `url_verification` handshake, answered synchronously. Subscribe to
`message.channels` and `app_mention`. In a channel the bot replies only when
`@mentioned` (the default; `require_mention: "false"` answers every message); a direct
message always replies.

### Discord (Interactions endpoint)

Discord runs over slash commands, not a gateway bot. Config: `public_key` (the app's
public key, hex, for the required Ed25519 signature check) and `application_id` (used
to post the follow-up answer). Set the app's "Interactions Endpoint URL" to the
connection URL and add a slash command with a text option (e.g. `/ask prompt:...`) -
the option's value is the prompt you receive. Discord demands a synchronous ack within
3s, so the command is answered with a deferred response and your real reply is posted
as a follow-up once you finish. A `from` here is the interaction token, not a user id.

### Microsoft Teams (Bot Framework)

Config: `app_id` (the bot's Microsoft app/client id), `app_password` (the client
secret) and `tenant_id` (the Azure tenant, or `botframework.com`). Set the bot's
messaging endpoint to the connection URL. Replies go back to the activity's
`serviceUrl` with an app access token minted via client credentials. The inbound Bot
Framework JWT **is** validated here (signature + `aud` == `app_id`), so the endpoint
accepts POSTs straight from Microsoft; set `trust_proxy: true` only if a proxy already
does that check. A 1:1 chat always
replies; in a team channel or group chat the bot replies only when `@mentioned`
(default; `require_mention: "false"` to answer all). The bot @mention is stripped from
the text before it reaches you.

### Google Chat (Chat API)

Config: `access_token` (an OAuth token for the Chat API, the Bearer for replies -
refresh it out of band) and `project_number` (the Cloud project number the Chat app is
registered under - its "Authentication Audience" setting must be **Project Number**,
not "HTTP endpoint URL", which is a differently-shaped token this doesn't verify).
Point the app's webhook (HTTP) endpoint at the connection URL. Only human `MESSAGE`
events become a turn; replies post back to the space. The inbound Google JWT **is**
validated here (signature + `aud` == `project_number`), so the endpoint accepts POSTs
straight from Google; set `trust_proxy: true` only if a proxy already does that check.
A DM always replies; in a multi-person space the app replies only when `@mentioned`
(default; `require_mention: "false"` to answer all).
