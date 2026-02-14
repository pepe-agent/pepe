# Cortex 🧠

**An Elixir/OTP AI agent runtime** — define agents, connect to any model, and run
a tool-calling loop, built to lean on Elixir's strengths: OTP supervision, a
process per conversation, first-class concurrency, and a tiny streaming HTTP
stack.

It exposes those core capabilities several ways:

| Surface | Endpoint | Use it for |
|---|---|---|
| **Web dashboard** | `GET /` (Phoenix LiveView) | Browse sessions and chat from the browser |
| **OpenAI-compatible HTTP** | `POST /v1/chat/completions`, `GET /v1/models` | Point any OpenAI SDK / LangChain / `curl` at Cortex |
| **WebSocket** | `ws://…/socket/websocket`, topic `agent:<name>` | Live, token-streamed conversations |
| **Telegram** | long-polling gateway | Chat with your agent from your phone |
| **TUI console** | `mix cortex tui` | A session-backed REPL in your terminal |
| **CLI** | `mix cortex …` | Create agents & model connections, run, serve |

Everything talks to providers over the **OpenAI Chat Completions** protocol using
[`Req`](https://hexdocs.pm/req), so OpenAI, OpenRouter, Together, Groq, DeepSeek,
Mistral, z.ai/GLM, Kimi/Moonshot, MiniMax, NovitaAI, Ollama, LM Studio, vLLM,
llama.cpp and any other compatible endpoint work with zero code changes.

---

## Architecture

```
                       ┌──────────────────────────────────────────┐
   CLI (mix cortex) ───▶ │            Cortex.Agent (facade)          │
   HTTP /v1/...   ───▶ │   oneshot / chat (keyed sessions)         │
   WebSocket      ───▶ │                                           │
   Telegram       ───▶ │   Cortex.Agent.Runtime  ── the loop ──────┼──▶ tools
                       │     ├─ Cortex.LLM (Req, OpenAI proto)      │     (bash, files,
                       │     │    chat/3 + stream_chat/4 (SSE)      │      web, http…)
                       │     └─ Cortex.Tools (behaviour + registry) │
                       └──────────────────────────────────────────┘
                                        │
                       Cortex.Config  ─ ~/.cortex/config.json (models, agents, gateways)
```

* **`Cortex.Config`** — file-backed store (`~/.cortex/config.json`). Secrets may be
  written as `${ENV_VAR}` and are interpolated at read time. No database required.
* **`Cortex.LLM`** — `Req`-based OpenAI client; `chat/3` (blocking) and
  `stream_chat/4` (SSE, with a per-fragment callback). Assembles streamed tool calls.
* **`Cortex.Tools`** — a `@behaviour` plus a built-in registry: `bash`, `run_script`,
  `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir`, `fetch_url`,
  `web_search`, `skill`, plus self-configuration tools (`config_get`, `config_set`,
  `enable_tool`, `rename_agent`). Drop-in `.exs` plugins extend it with no recompile.
* **`Cortex.Agent.Runtime`** — the conversation loop: call model → run tool calls →
  feed results back → repeat until a final answer or `max_iterations`. Emits
  lifecycle events (`:assistant_delta`, `:tool_call`, `:tool_result`, `:done`).
* **`Cortex.Agent.Session`** — one GenServer per conversation key (e.g.
  `telegram:12345`), supervised by a `DynamicSupervisor` + `Registry`. Each run
  executes off-process so the session stays responsive (e.g. to `/stop`). Crash
  isolation and context retention for free.
* **`Cortex.Permissions`** — gates risky tool calls (running code, writing files,
  changing config). Each surface renders the prompt natively (Telegram buttons, the
  console's arrow-key menu); read-only tools run freely. See **Permissions** below.
* **Gateways** — `Cortex.Gateways.Telegram` (long polling) and `Cortex.Gateways.TUI`
  (the console). They start only when requested (`serve`/`gateway`), so a local
  `run`/`tui` never spins up the Telegram poller.

> **Where surfaces live.** `lib/cortex/gateways/` holds the **non-web** surfaces
> (the Telegram poller, the TUI console). Everything served by the Phoenix endpoint
> — the OpenAI-compatible API, the WebSocket channel, and the LiveView dashboard —
> lives in `lib/cortex_web/`, since those are bound to the router/endpoint/layouts.
> So the dashboard is in `lib/cortex_web/live/`, alongside the other web surfaces,
> not under `gateways/`.

---

## Quick start

```bash
mix deps.get

# 1) scaffold ~/.cortex/config.json
mix cortex setup

# 2) add a model connection (any OpenAI-compatible provider)
mix cortex model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model anthropic/claude-3.5-sonnet \
  --default

# 3) define an agent (defaults to all built-in tools)
mix cortex agent add assistant \
  --prompt "You are Cortex, a helpful coding agent." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default

# 4) run it
export OPENROUTER_API_KEY=sk-...
mix cortex run "list the files here and summarize the project"
```

## CLI reference (`mix cortex`)

> In development use `mix cortex …`. The standalone `cortex` binary
> (`mix escript.build`, or a Burrito release) takes the same subcommands.

### Setup

```bash
mix cortex setup        # first run: guided wizard (language → model → agent → Telegram)
                        # later runs: a menu to add/reconfigure any part
```

### Model connections

```bash
mix cortex model                       # show the default + switch among saved / add a new one
mix cortex model add openai            # guided: pick provider → auth method → model
mix cortex model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model anthropic/claude-3.5-sonnet --default      # fully manual
mix cortex model providers             # list known providers (OpenAI, Anthropic, Gemini, …)
mix cortex model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
mix cortex model list                  # list saved connections
mix cortex model test [NAME]           # ping a connection to verify the key/endpoint work
mix cortex model remove openrouter
mix cortex model default openai
```

ChatGPT/Codex and Claude Pro/Max can be added by **subscription sign-in** —
`mix cortex model add openai` → "ChatGPT / Codex subscription" opens your browser
(OAuth PKCE), captures the token, and refreshes it automatically.

### Agents

```bash
mix cortex agent add assistant \
  --prompt "You are a helpful coding agent." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
mix cortex agent list
mix cortex agent route zak helper        # let zak message another agent (see Routing)
mix cortex agent rename assistant zak   # rename + move its workspace dir (~/.cortex/agents/<name>/)
mix cortex agent remove zak
mix cortex agent default assistant
mix cortex agent help                    # (or `mix cortex help agent`)
```

### Companies (multi-tenant, optional)

Host isolated tenants in one deployment. Without `--company`, everything uses the
**root** scope, exactly as a single-tenant install always has — so this is entirely
opt-in. Add `--company NAME` to scope a command to a company; its agents,
workspaces, `shared/` space and models are walled off from every other company (see
**[Companies](#companies-multi-tenant-isolation)**).

```bash
mix cortex company add acme --description "Acme Inc"     # create a tenant scope
mix cortex company list
mix cortex agent add vendas --company acme --prompt "…"  # agent "acme/vendas"
mix cortex agent list --company acme                     # only Acme's agents
mix cortex agent list --all                              # every scope
mix cortex run acme/vendas "hello"                       # run it by its handle
mix cortex company remove acme --force                   # drop the company + its agents
```

### Running

```bash
mix cortex run "list the files here and summarize the project"   # one-shot, streams to stdout
mix cortex run assistant "hello"                                 # pick an agent explicitly
mix cortex tui                         # interactive console, keeps the session
mix cortex tui --agent zak             # …with a specific agent (or: mix cortex tui zak)
mix cortex serve --port 4000           # OpenAI-compatible HTTP API + WebSocket
```

`tui` (alias: `chat`) opens a session-backed console — it keeps context across
turns and prints a summary box (agent · model · session) on open. The same slash
commands as the other gateways work: `/new`, `/undo`, `/compact`, `/status`,
`/agent <name>`, `/help`, `/exit`. Replies stream as they arrive, and a risky tool
asks for permission through an arrow-key menu (see **Permissions**).

### Telegram gateway

```bash
mix cortex gateway telegram setup      # interactive: bot token, allowlists, which agent
mix cortex gateway telegram            # run the gateway in the foreground (long-polling)
```

### Misc

```bash
mix cortex tools                       # list available tools (built-ins + plugins)
mix cortex timelearn [AGENT]           # what the agent has learned, on a timeline
mix cortex cron list|add|run|logs …    # scheduled tasks (see Scheduled tasks)
mix cortex config                      # show config path + a summary
mix cortex help                        # full command help (or: help <group>)
```

## Web dashboard

A Phoenix LiveView dashboard at **`/`** — a live list of sessions on the left and a
streaming chat panel on the right. Pick a session to read its history and talk to
its agent; replies stream in token-by-token. `New chat` starts a fresh session, and
each session shows its agent, model and turn count. The left sidebar mirrors the
CLI, so almost everything you can do with `mix cortex` you can do here:

- **Chat** — talk to a session (risky tools prompt inline).
- **Companies** — create/edit/delete tenant scopes and their billing markup (see **Companies**).
- **Agents** — create/edit/delete agents: persona, model, tools, routes, admin scope,
  default.
- **Models** — add/remove/edit model connections, set per-model prices, pick the default.
- **Usage & billing** — token usage and cost by cycle, per company (see **Usage metering & billing**).
- **Learning** — the TimeLearn timeline (see **Learning**).
- **Scheduled** — create/run/manage scheduled tasks (see **Scheduled tasks**).
- **Watches** — one-shot "notify me when X" (see **Watches**).
- **Channels** — add/remove/edit Telegram bots, applied live (see **Telegram → Multiple bots**).
- **MCP** — external tool servers (see **MCP servers**).
- **Config file** — edit `~/.cortex/config.json` inline, validated on save.

```bash
mix assets.build          # once (builds css/js)
mix cortex serve          # API + dashboard + gateways, one process
# open http://localhost:4000
```

Because sessions are in-process, run everything from the **one** `mix cortex serve`
process and the dashboard sees every session — including the ones from Telegram.
Risky tools are authorized inline on the dashboard too: the run pauses and shows an
allow/deny prompt (the web version of the Telegram buttons), unless the agent has
pre-approved the tool (the omnipotent primary agent never prompts).

## OpenAI-compatible HTTP API

```bash
mix cortex serve         # or: PHX_SERVER=true mix phx.server
```

```bash
# The "model" field selects an Cortex AGENT by name (so its tools/persona apply);
# falls back to a bare model connection, then the default agent.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hello"}]}'

# streaming (Server-Sent Events)
curl -N http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","stream":true,"messages":[{"role":"user","content":"hi"}]}'

curl http://localhost:4000/v1/models
curl http://localhost:4000/health
```

Works with the official OpenAI SDKs — just set the base URL to
`http://localhost:4000/v1` and the model to your agent's name.

### Access tokens (per company or per agent)

The `/v1` API is **open until you create the first token** — then every call needs
a valid `Authorization: Bearer ctx_…`. A token is stored only as a SHA-256 hash (the
raw value is shown once), and its scope decides what it can reach:

| Scope | Created with | Can call |
| --- | --- | --- |
| **Agent** | `--agent HANDLE` | only that agent (the `model` field is ignored) |
| **Company** | `--company CO` | any agent in that company (bare names qualify into it); other companies → `403` |
| **Root** | neither | root agents + bare model connections |

```bash
mix cortex token add --company acme --label "acme mobile app"   # prints ctx_… once
mix cortex token add --agent acme/vendas --label "single integration"
mix cortex token list       # id · fingerprint · scope · label
mix cortex token revoke <id>

# then callers must authenticate
curl http://localhost:4000/v1/chat/completions \
  -H 'authorization: Bearer ctx_…' \
  -H 'content-type: application/json' \
  -d '{"model":"vendas","messages":[{"role":"user","content":"oi"}]}'   # "vendas" → acme/vendas
```

The token is read from `Authorization: Bearer …` (the OpenAI standard, what the
official SDKs send) or, as a fallback, the Azure-style `api-key: …` header.

`GET /v1/models` is filtered to the token's scope, so a client only ever sees the
agents it may use. This is what makes the [company isolation](#companies-multi-tenant-isolation)
real over the network — without a token the API can reach any agent.

### Stateful sessions

By default the endpoint is stateless (you send the full `messages` array each
time, like OpenAI). Pass a **session id** and the server keeps the whole
conversation for you — then you only need to send the latest user message.

Three equivalent ways (first match wins):

* `"session_id": "abc"` in the JSON body, **or**
* `"user": "abc"` — the standard OpenAI field, **or**
* an `X-Session-Id: abc` request header.

```bash
# turn 1
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"my name is John Doe"}]}'

# turn 2 — same "user", server remembers turn 1
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"what is my name?"}]}'
```

Each session is a supervised GenServer keyed by `api:<id>` (`Cortex.Agent.Session`).
Streaming works with sessions too. WebSocket and Telegram are stateful by design
(per-connection / per-chat-id). An empty `user`/`session_id` (`""`) is treated as
stateless.

## WebSocket

Connect to `ws://localhost:4000/socket/websocket` (Phoenix Socket protocol) and
join topic `agent:<name>` (`agent:default` for the default agent).

* push `"prompt"` `{ "text": "…" }` → receive streamed `"delta"`, `"tool_call"`,
  `"tool_result"`, then `"done"` events.
* push `"reset"` to clear history.

Auth mirrors the [`/v1` API](#access-tokens-per-company-or-per-agent): open until
tokens exist, then pass one as a **connect param** (a WebSocket can't set headers) —
`ws://localhost:4000/socket/websocket?token=ctx_…`. The token's scope is enforced on
`join`: a client can only join `agent:` topics its token allows (`agent:default`
resolves to the scope's default), and a company token joining another company's agent
is refused. Bare names qualify into the token's company (`agent:vendas` → `acme/vendas`).

## Telegram

Configure interactively (creates a bot via [@BotFather](https://t.me/BotFather)
first), then run the long-polling gateway (no webhook needed):

```bash
mix cortex gateway telegram setup      # bot token, allowlists, which agent answers
mix cortex gateway telegram            # run it
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
blocked, chat/user gone), that chat is skipped on every further send — no wasted API
calls or log noise — and automatically un-marked the moment a send to it succeeds
again (e.g. the user un-blocked the bot). No manual reset needed.

**"Working" activity while the agent runs** is deliberately ambient, not a status
report you're meant to read. Tune it per bot with `tool_progress`:

- `reaction` (default) — a 👀 reaction on your own message while the agent works,
  cleared when the answer lands. No extra message in the chat; the quietest signal.
- `ambient` — a single vague line ("🔎 looking things up…", "💻 running something…")
  edited in place and deleted when done. No tool names, args or ledger.
- `off` — nothing but the native "typing…" indicator.
- `verbose` — a per-tool breadcrumb list (for power users).

The native "typing…" indicator stays alive across all modes. Set it from chat
(`manage_channel` → `set_progress`) or the CLI (`--progress`).

### Heartbeat — proactive check-ins (opt-in)

A bot can periodically give its agent the floor to say something **on its own
initiative** ("the deploy finished", "you asked me to watch for X") — and, just as
importantly, the right to say **nothing** most of the time. Off by default:

```bash
# via the manage_channel tool (an agent can set this up itself, from chat):
manage_channel set_heartbeat name: "sales" heartbeat_minutes: 30 heartbeat_hours: "8-22"
```

Each pulse runs the agent on its session's live context with a prompt that says
"this is an automatic check — reply with exactly `HEARTBEAT_OK` if there's nothing
worth saying." That's the common case; only a genuine message gets sent. Feed it:

- an optional `HEARTBEAT.md` in the agent's workspace ("what to watch for"),
- **system events** any part of Cortex can queue for a session
  (`Cortex.Heartbeat.Events.push/2`) and the next pulse picks up automatically.

A cooldown gate (30s min spacing, a 5-fires/60s flood breaker) makes a runaway
proactive loop impossible, and `heartbeat_hours` ("8-22") keeps it quiet outside
local waking hours.

### Multiple bots, one per agent

You can run **several bots at once, each bound directly to its own agent** — one
Telegram bot *is* agent X, another *is* agent Y. Cortex starts one poller per bot;
each has its own token, bound agent, allowlists and session namespace.

```bash
mix cortex gateway telegram setup                        # the default bot
mix cortex gateway telegram add sales --token $T --agent sales-bot
mix cortex gateway telegram add ops   --token $T2 --agent ops-bot
mix cortex gateway telegram list                         # see them all
mix cortex gateway telegram                              # runs every bot
```

The default bot lives under `"telegram"`; extra bots under `"telegrams"` (a
name→config map) in `~/.cortex/config.json`, each accepting the same keys. Bots
that resolve to the same token are de-duplicated (two pollers on one token would
conflict). The default bot keeps the `telegram:<chat_id>` session key; named bots
use `telegram:<name>:<chat_id>`, so their conversations (and cron delivery) never
collide. You can also manage bots live from the **Bots** tab in the dashboard —
add/remove there and the running pollers reconcile without a restart.

Within a single bot you can still switch agent per chat with `/agent X` (see
**Agent-to-agent routing**); dedicated bots are for when a whole channel should
*be* one agent.

#### Let an agent add a bot from chat

An agent can create and manage bots itself with the `manage_channel` tool — *"add
a bot for the sales agent, token in `$SALES_BOT_TOKEN`"* — as long as the tool is in
its allowlist. It's guarded two ways:

- **Permission gate** — `manage_channel` is a risky tool, so each call is authorized
  by the human (or pre-approved), like any risky tool.
- **Scoped** — it only touches named bots, never the protected `default` bot or any
  other config.
- **Secrets never pass through the chat** — you give the *name of an environment
  variable* holding the token (`token_env: "SALES_BOT_TOKEN"`), not the token; it's
  stored as `${SALES_BOT_TOKEN}` and resolved at read time, so the raw secret never
  reaches the model or the logs. Set that env var yourself.

After a change the running pollers reconcile live. Actions: `add`, `list`,
`set_agent`, `enable`, `disable`, `remove`.

## Admin agents (manage & train other agents)

An agent can administer and **train other agents** — set their persona, model, tools,
and memory, or create new ones — with the `manage_agent` tool. Authority is a
**directed, per-agent allowlist** (`can_manage`), so you can have several admins,
each scoped to different agents:

| `can_manage`      | means                                             |
|-------------------|---------------------------------------------------|
| *omitted* / `nil` | itself only (default)                             |
| `[]`              | nobody, not even itself (a locked client agent)   |
| `[a, b]`          | exactly those (add its own name to include self)  |
| `["*"]`           | every agent (an explicit super-admin)             |

```bash
mix cortex agent manage boss vendas        # boss can now administer "vendas"
mix cortex agent manage boss "*"           # a super-admin over all agents
mix cortex agent add child --can-manage none   # a locked agent that can't alter itself
```

`manage_agent` actions: `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool`, `remember` (append a fact to the target's memory). It's a
risky tool, so each use is authorized through the permission gate; persona and memory
live in the target's workspace, tools/model in its config.

## Permissions

The **primary agent** — the one created on first `mix cortex setup` (the owner's own
agent) — is born **omnipotent**: every tool, super-admin over all agents
(`can_manage: ["*"]`), and a `"*"` auto-approve grant so it runs any tool without a
prompt. It can do everything via chat from the start. Agents you add later are
scoped normally.

Before a **risky** tool runs — running code (`bash`, `run_script`), writing/moving
files, changing config, or any plugin tool — Cortex asks you to authorize it
(unless the agent has approved it — `"*"` approves everything).
Read-only tools (`read_file`, `list_dir`, `fetch_url`, `web_search`, …) run freely.

Each surface renders the prompt natively — **Telegram** shows inline buttons, the
**console** an arrow-key menu — but the four choices are the same everywhere:

| Choice | Effect |
|---|---|
| **Allow once** | just this call; ask again next time |
| **Allow for this session** | the rest of this session (forgotten on `/new` and on restart) |
| **Always allow** | from now on — persisted on the agent (`auto_approve` in `config.json`) |
| **Don't allow** | refuse; never remembered, so it's asked again |

Manage the persistent grants from chat with `/approve` (list), `/approve clear`, or
`/approve clear <tool>`. Surfaces with no human to ask (the HTTP API) run tools
without prompting.

## Agent-to-agent routing

Agents can message each other through the `send_to_agent` tool, governed by a
**directed allowlist** — each agent's `can_message` lists who *it* may message, so
`A → B` does **not** imply `B → A`. The called agent answers in a fresh run and its
reply comes back as the tool result; a hop limit and cycle check stop chains from
looping.

```bash
# A can message B; B can message C and D; C can message A and B
mix cortex agent route A B
mix cortex agent route B C
mix cortex agent route B D
mix cortex agent route C A
mix cortex agent route C B
mix cortex agent route A B --remove        # revoke a route

# or set it when creating the agent
mix cortex agent add A --model mock --can-message B
```

```jsonc
"agents": {
  "A": { "can_message": ["B"] },
  "B": { "can_message": ["C", "D"] },
  "C": { "can_message": ["A", "B"] }
}
```

Add `send_to_agent` to an agent's `tools` to let it route. The route allowlist is
the authorization, so the call itself isn't put through the human permission gate —
but the callee's own risky tools still are.

Routes can also be changed **from chat**: give an agent the `set_route` tool and it
can add/remove routes (`{from, to, action}`, `from` defaults to itself) — guided by
the `manage-routing` skill. Since it edits config, the change goes through the
permission prompt.

## Companies (multi-tenant isolation)

Optional. A **company** is an isolated tenant scope, so one deployment can serve
many clients whose data never crosses. It is entirely opt-in: with no company,
everything lives in the **root** scope — identical to a single-tenant install — and
that's what every command uses without `--company`. Most deployments never need a
company; add one only when you must wall tenants off.

An agent's identity is a **handle**: a bare name in root (`vendas`) or
`company/name` inside a company (`acme/vendas`). The same bare name can be reused
per company — `acme/vendas` and `globex/vendas` are different agents. Because the
handle is what keys everything (config, workspace, sessions, routes), isolation
follows automatically:

- **Files** — a company agent's workspace is `~/.cortex/companies/<co>/agents/<name>/`
  and its shared space is `~/.cortex/companies/<co>/shared/`, so equally named agents
  in different companies never collide and `shared/…` paths never leak across tenants.
  Root agents keep `~/.cortex/agents/<name>/` and `~/.cortex/shared/`.
- **Routing** — `send_to_agent` never crosses companies: a bare target resolves to a
  peer in the sender's own company, and a hard guard refuses any cross-company route
  even if an allowlist asks for it.
- **Models/keys** — a company agent resolves its own models first, then root, so a
  company can pin private provider keys other companies can't see — or inherit one
  shared global provider. A company agent/model never becomes the global default.

```bash
mix cortex company add acme --description "Acme Inc"
mix cortex company add globex
mix cortex company list

# agents, models, routes all take --company
mix cortex model add llm  --company acme --base-url … --api-key '${ACME_KEY}' --model …
mix cortex agent add vendas  --company acme --prompt "…" --can-message suporte
mix cortex agent add suporte --company acme --prompt "…"
mix cortex agent route vendas suporte --company acme   # both resolve inside acme

mix cortex agent list --company acme    # only Acme's
mix cortex agent list                   # only root
mix cortex agent list --all             # every scope
mix cortex tui --company acme vendas    # or: mix cortex run acme/vendas "…"

mix cortex company remove acme          # refuses while it owns agents…
mix cortex company remove acme --force  # …unless forced (drops its agents too)
```

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // root scope
  "acme/vendas":  { "can_message": ["acme/suporte"] },
  "acme/suporte": { "can_message": [] }
}
```

A Telegram bot bound to a company agent keeps its whole conversation inside that
company; without a company it serves root, as before.

## Configuration (`~/.cortex/config.json`)

```jsonc
{
  "default_model": "openrouter",
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "anthropic/claude-3.5-sonnet",
      "max_tokens": 4096
    }
  },
  "default_agent": "assistant",
  "agents": {
    "assistant": {
      "model": "openrouter",
      "system_prompt": "You are Cortex, a helpful agent.",
      "tools": ["bash", "run_script", "read_file", "write_file", "edit_file", "list_dir", "fetch_url", "web_search"],
      "auto_approve": ["read_file"],
      "max_iterations": 12
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [], "require_mention": true },
  "locale": "en",
  "server": { "port": 4000 }
}
```

Override the location with `CORTEX_HOME` (directory) or `CORTEX_CONFIG` (file).
Each agent also gets a persistent directory at `~/.cortex/agents/<name>/` holding
its `SOUL.md` (persona) and any files it creates (`MEMORY.md`, `people.md`, …);
`~/.cortex/shared/` is shared across agents.

An agent with **no identity yet** (no `SOUL.md`, default seed) presents itself as
Cortex, tells you it has no name or characteristics defined, and offers to set one
up — then saves your choices to `SOUL.md` and renames itself with `rename_agent`.
`auto_approve` lists tools the agent may run without asking (see **Permissions**).

### Storage & backup — it's all files, no database

Everything lives under `~/.cortex/` (or `CORTEX_HOME`) — there is **no database
server**. `config.json` is the single source of truth (companies, agents, models,
watches, crons, bots, MCP, hashed API tokens). Agent knowledge lives as files in
`agents/<name>/` and `companies/<co>/agents/<name>/`; conversation history in
`data/sessions/`; `data/mnesia/` is a disposable cache (rebuilds itself). `Cortex.Repo`
+ Postgres exist in the code but are **off** (`ecto_repos: []`) — the door for a future
DB backend, unused today.

Secrets are never stored raw — they're `${ENV_VAR}` references resolved at read time,
so they live in your environment, not the files.

Back up with one command — it archives the durable parts, skips the disposable cache,
and lists the secret env vars you must save separately (they're not in the archive):

```bash
mix cortex backup                       # → cortex-backup-YYYY-MM-DD.tgz
mix cortex backup --output /path/x.tgz
```

Restore = extract back into `~/` (or `CORTEX_HOME`'s parent) and re-export those env
vars. That's the whole disaster-recovery story.

## MCP servers (external tools)

Connect **MCP (Model Context Protocol)** servers — Sentry, GitHub, … — and their
tools become callable by agents as if built in. Servers launch over stdio on demand
(via `npx`, so **nothing to install manually**); tokens go in as `${ENV_VAR}` refs.

```bash
mix cortex mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
mix cortex mcp tools sentry     # launch it and list its tools (validate the connection)
mix cortex mcp list
```

Each MCP tool is exposed as `mcp__<server>__<tool>`. **Scoping is just the tool
allowlist** — to make an agent *read-only* against a server, give it only the read
tools and leave the mutating ones out:

```bash
mix cortex agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (no mcp__sentry__update_issue → the agent can look, not change)
```

`mcp__sentry__*` grants all of a server's tools. MCP tools are risky, so each call
still goes through the permission gate. An agent with the `manage_mcp` tool can add
and validate servers itself from chat (secrets stay as `${ENV}` refs). Definitions
live in `~/.cortex/config.json` under `"mcp"`.

## Self-knowledge & self-management (how an agent operates Cortex)

Cortex is designed so an agent can **resolve requests about Cortex itself** — "add a
bot", "schedule this", "connect Sentry", "switch the timezone" — without bespoke
hand-holding, and without ever being dangerous:

- **It reads its own docs.** How-to guides ship under `priv/docs/` (agents, channels,
  cron, MCP, permissions, config) and are listed in every agent's system prompt as
  the *authoritative* source; the read-only `docs` tool loads the relevant one on
  demand. New/unforeseen requests get resolved by reading, not guessing. (Drop extra
  guides in `~/.cortex/docs/` to extend or override.)
- **It discovers what's editable.** `config_set` called with no arguments returns the
  schema — the editable settings, their current values and accepted values. The
  editable set is a **fail-closed allowlist** (`default_model`, `default_agent`,
  `language`, `timezone`, `telegram.require_mention/enabled`); anything else is
  refused with a pointer to the right guarded tool (`manage_agent`, `manage_channel`,
  `manage_mcp`, `schedule_task`). Secrets are never editable from chat.
- **It verifies its own work.** After changing something, the agent (or you) runs the
  **doctor**: offline checks (every `${ENV}` ref resolves, agents point at real
  models and known tools, cron schedules/timezones/agents are valid) plus live probes
  (Telegram `getMe` per bot, a ping per model connection, an MCP launch + tool list
  per server).

```bash
mix cortex doctor              # live probes (Telegram, models, MCP)
mix cortex doctor --offline    # config-consistency only, no network
```

The loop is **do → verify → correct**: structured guarded tools for the hot paths,
generic tools + docs for everything else, and the doctor to confirm it worked.

## Adding a tool

A tool is any module implementing the `Cortex.Tools.Tool` behaviour
(`name/0`, `spec/0`, `run/2`). Two ways to ship one:

**Built-in** (compiled in) — add the module under `lib/cortex/tools/` and list it
in `@builtin` in `Cortex.Tools`:

```elixir
defmodule Cortex.Tools.MyTool do
  @behaviour Cortex.Tools.Tool
  import Cortex.Tools.Tool, only: [function: 3]

  def name, do: "my_tool"
  def spec, do: function("my_tool", "what it does", %{"type" => "object", "properties" => %{}})
  def run(_args, _ctx), do: {:ok, "result text"}
end
```

**Plugin** (drop-in, no recompile) — put the same module in a `.exs` under
`~/.cortex/plugins/`. It's compiled at runtime, hot-reloaded on change (by mtime),
and appears in `mix cortex tools`. Add its `name` to an agent's `tools` to enable
it:

```elixir
# ~/.cortex/plugins/weather.exs
defmodule CortexPlugins.Weather do
  @behaviour Cortex.Tools.Tool
  import Cortex.Tools.Tool, only: [function: 3]

  def name, do: "weather"
  def spec, do: function("weather", "Get the weather for a city.",
    %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}, "required" => ["city"]})
  def run(%{"city" => city}, _ctx), do: {:ok, "Sunny in #{city}"}
end
```

## Skills

Skills are on-demand instruction docs (Markdown) that teach an agent a *procedure*
— e.g. how to install a tool. They are listed (name + one-line summary) in the
agent's context, and the agent reads the relevant one with the `skill` tool when
its topic comes up, so they don't bloat every prompt.

- **Built-in** skills ship under `priv/skills/*.md`:
  - `skill-creator` — how to create, edit, audit and improve skills (the meta-skill).
  - `install-tool` — write a plugin tool and enable it from chat.
  - `write-a-script` — solve complex tasks by writing/saving a program to run.
  - `manage-routing` — change agent-to-agent routes with `set_route`.
  - `handle-media` — understand a voice/audio/image/file (transcribe, read), installing
    what it needs.
- **User** skills live in `~/.cortex/skills/*.md` and override a built-in of the
  same name. The first non-empty line is the summary; the rest is the procedure.

An agent can **author its own skills**: ask it to "remember how to do X as a skill"
and (guided by `skill-creator`) it writes a new `skills/<name>.md` — which then
appears in its skills list, no restart.

Combined with plugins + `enable_tool`, an agent can be asked in chat to "install a
tool that does X": it reads the `install-tool` skill, writes the plugin to
`plugins/<name>.exs`, enables it on itself, and uses it — no restart.

For complex/multi-step work the agent doesn't grind it out by hand — the
`run_script` tool lets it write a short program (Python, Node, Ruby, Bash, or
Elixir — Elixir is always available) and run it, getting back stdout/stderr/exit
code and iterating on errors. Worthwhile scripts are **saved** under `scripts/` and
re-run later (`run_script` with `file:`), and when the agent works out *how* to do
a recurring task (read a PDF, crunch a spreadsheet) it **writes itself a skill** to
`skills/<name>.md`. The `write-a-script` skill teaches the whole loop.

## Learning (self-improvement + TimeLearn)

An agent can **turn conversations into lasting knowledge on its own** — the
"reflect" loop. It learns only from **trusted conversations** so a client's chat
never becomes memory. Who counts as trusted is a per-bot `trainers` allowlist:

- **`["*"]`** → learns from everyone
- **`[]`** → learns from no one (a client-facing bot)
- **`[id1, id2]`** → learns only from those user ids (your ids — the trainers)
- **omitted / `null`** → the default (everyone)

The allowlist convention is the same everywhere in Cortex: `["*"]` = all, `[]` =
none, `[items]` = exactly those, and omitted/`null` = that field's default.

```bash
mix cortex gateway telegram add support --token $T --agent helper --trainers none
# a client-facing bot that never learns; your own DM bot (no --trainers) still does
```

After a trusted session the agent **reviews the conversation** and updates two
things, kept separate:

- **Memory** (about *you*) → `USER.md` / `MEMORY.md` / `people.md`, kept lean
  (it consolidates instead of piling on).
- **Skills** (about *technique*) → prefers updating a rich existing skill over
  spawning a narrow new one.

The review is a background run with tools restricted to file/skill management (no
shell/network), so it can update the workspace but nothing else; the live session
is untouched. It fires on `/compact`, on idle (~90s after the last turn), and on
demand with **`/learn`** (Telegram + console).

**TimeLearn** shows what an agent has learned, on a timeline — skills (🧠) and
memory entries (📝), newest first, with source and date:

```bash
mix cortex timelearn zak               # in the terminal
```

…or the **Learn** tab in the web dashboard (with an agent picker). The generator
(reflect) produces; TimeLearn displays.

## Scheduled tasks (cron)

Run an agent on a recurring schedule — a daily report, a periodic check — and
deliver the result to a chat (or nowhere). A task fires in a **fresh session with
no chat memory**, so its prompt must be self-contained.

Three ways to create and manage them:

**1. From the CLI** (`mix cortex cron`):

```bash
mix cortex cron add \
  --name "Daily XML check" \
  --prompt "Check the 06:00 XML load and report anything abnormal." \
  --schedule "0 8 * * *" \
  --timezone America/Sao_Paulo \
  --deliver telegram:123456        # or omit / "none" to report nowhere
mix cortex cron list               # all tasks + next run time
mix cortex cron run daily-xml-check   # force it now (preview)
mix cortex cron logs daily-xml-check  # recent run history
mix cortex cron disable daily-xml-check
mix cortex cron remove daily-xml-check
```

The schedule is a standard 5-field cron expression; the timezone is any IANA name
(`America/Sao_Paulo`, `Europe/Berlin`, …) — nothing is hard-coded. The default
timezone is set at `mix cortex setup` and used when a task doesn't name its own.

**2. From the web dashboard** — the **Cron** tab lists every task with its next
run, a **Run now** button, enable/disable/remove, and a form to create one
(agent, prompt, schedule, timezone, model, and *where to deliver* — including
"Don't send anywhere"). Each task keeps a run history you can expand.

**3. By asking the agent in chat** — *"every day at 8am Brasília time, check the
XML load and tell me here."* The agent creates the task with the `schedule_task`
tool (which must be in its allowlist), baking the context into the prompt. It's a
risky tool, so each use is authorized through the permission gate (or pre-approved).
When created from a chat, a task reports back to that same chat by default. The
agent can also `run` a task on demand from the conversation.

Tasks fire from an in-process timer that only runs while `mix cortex serve` or
`mix cortex gateway` is up (never during one-shot commands). Due tasks each run in
their own process, so they fire concurrently — one slow task never blocks another.
Definitions live in `~/.cortex/config.json` (`"crons"`); run history in
`~/.cortex/data/cron_logs/`.

## Watches — "notify me when X" (one-shot)

A **watch** is a durable, one-shot commitment: you ask the agent to *check something
and tell you when it happens*, it watches in the background, messages you **once**
when the condition is met, and then stops. Unlike a heartbeat (a periodic pulse) or a
cron (a recurring job), a watch fires exactly once and cleans itself up.

It's created on demand — the agent calls the `watch` tool when you ask
("avise quando o deploy concluir") — and it's **durable**: it survives a restart and
this session closing, and delivers back on the **channel you asked from**: Telegram
(direct push), a WebSocket session (a `"watch"` event — pass a stable `session` on
join to receive it across reconnects), or the TUI console (printed inline). If that
channel is momentarily unreachable, the message is held and retried until it lands.

The scheduler runs on whichever long-lived surface is up — `serve`, `gateway`, or an
interactive `tui`/`chat`. Run **one at a time** against the same config; two would
both tick and double-fire.

Two cost tiers, chosen at creation so checking stays cheap:

- **`probe`** — a shell command polled every interval, **no LLM per check** (success =
  exit 0, or a substring match). Best for scriptable conditions ("site is back",
  "log contains `Deploy complete`").
- **`agent`** — re-ask the model each check, for conditions that need judgement.

…and the notification (`on_fire`) is either a fixed **template** (no LLM) or an
**agent**-composed message (one LLM call, only when it fires). The powerful combo is a
free probe gating an agent message: poll `curl` for nothing, and only let the model
write the summary the moment it passes.

```bash
# from chat: "avise quando o site x voltar" → the agent creates a probe watch.
# from the CLI (probe watches):
mix cortex watch add "site x up" --probe "curl -sf https://x" --message "✅ voltou" --every 60
mix cortex watch list
mix cortex watch pause <id> | resume <id> | cancel <id>
```

Manage them three ways — dashboard **Watches** tab, chat ("para o watch do site" →
the agent lists and cancels via the `watch` tool), or the CLI — all reading the same
durable store (`~/.cortex/config.json`, `"watches"`). The scheduler ticks only while
`serve`/`gateway` is up; the updated state is persisted **before** delivery, so a
crash can't double-fire.

## Usage metering & billing

Every model call is metered and attributed to the agent's company, so you can bill a
client per token. Metering happens at the one point all surfaces flow through (CLI,
HTTP `/v1`, WebSocket, Telegram) and appends to a durable, append-only ledger under
`~/.cortex/data/usage/<company>/YYYY-MM.jsonl` — the audit trail for what's charged.

**Cost** = `tokens × the model's price` (per 1M tokens). A price is resolved in
layers: the **manual price** on the model wins, then a **live cache**
(`~/.cortex/data/price_book.json`, refreshed from OpenRouter + the LiteLLM price
map), then a **built-in seed** of well-known prices (offline fallback). So known
models are priced automatically; you only type a price to override or fill a gap.

**Amount to bill** = `cost × the company's markup` — an optional per-company
multiplier (`1.3` = +30%; blank = bill exactly the provider cost). Both the provider
cost and the amount to bill are always shown side by side, so the markup never hides
the real cost from your team.

```bash
mix cortex usage                                  # all scopes, by month, per company
mix cortex usage --company acme --granularity day # a company, by day
mix cortex usage export --company acme            # a client invoice (Markdown or --format csv)
mix cortex usage prices --refresh                 # refresh the live price cache
```

**Invoices.** `usage export` turns a company's month into a client invoice (Markdown
or CSV), and the `export_invoice` **tool** lets an agent do it itself — so a monthly
scheduled task can export each client's invoice and send it, using Cortex to bill for
its own use.

Prices also auto-refresh once a week while `serve`/`gateway` is up. In the dashboard,
the **Usage & billing** section shows tokens, cost and amount-to-bill by cycle
(hour / day / week / month / year) with breakdowns by company, model and agent; set
per-model prices under **Models → Edit** and a company's markup under
**Companies → Edit**. Currency is a label only (default `USD`, set `"currency"` in
config); there's no FX conversion. Full walkthrough: `mix cortex` doc **billing**.

## Tests

```bash
mix test
```

The suite stands up a real local OpenAI-compatible mock server (Bandit) and
exercises the full stack: non-streaming chat, SSE streaming, the tool-calling
loop, and the HTTP `/v1` endpoints — all over real TCP. No database needed.
