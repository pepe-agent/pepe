# Cortex 🧠

**An Elixir/OTP AI agent runtime** — define agents, connect to any model, and run
a tool-calling loop, built to lean on Elixir's strengths: OTP supervision, a
process per conversation, first-class concurrency, and a tiny streaming HTTP
stack.

It exposes those core capabilities several ways:

| Surface | Endpoint | Use it for |
|---|---|---|
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
mix cortex agent rename assistant zak   # rename + move its workspace dir (~/.cortex/agents/<name>/)
mix cortex agent remove zak
mix cortex agent default assistant
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
mix cortex config                      # show config path + a summary
mix cortex help                        # full command help
```

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
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"meu nome é Jho"}]}'

# turn 2 — same "user", server remembers turn 1
curl http://localhost:4000/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"assistant","user":"u-42","messages":[{"role":"user","content":"qual meu nome?"}]}'
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

## Permissions

Before a **risky** tool runs — running code (`bash`, `run_script`), writing/moving
files, changing config, or any plugin tool — Cortex asks you to authorize it.
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

- **Built-in** skills ship under `priv/skills/*.md` (e.g. `install-tool`).
- **User** skills live in `~/.cortex/skills/*.md` and override a built-in of the
  same name. The first non-empty line is the summary; the rest is the procedure.

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

## Tests

```bash
mix test
```

The suite stands up a real local OpenAI-compatible mock server (Bandit) and
exercises the full stack: non-streaming chat, SSE streaming, the tool-calling
loop, and the HTTP `/v1` endpoints — all over real TCP. No database needed.
