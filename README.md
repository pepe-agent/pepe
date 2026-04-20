<p align="center">
  <img src="assets/brand/pepe-mark.svg" alt="Pepe" width="120">
</p>

<h1 align="center">Pepe</h1>

<p align="center">
  <strong>An Elixir/OTP AI agent runtime.</strong> Define agents, connect to any model, and run a tool-calling loop.
</p>

<p align="center">
  Web dashboard &nbsp;·&nbsp; OpenAI-compatible HTTP &nbsp;·&nbsp; WebSocket &nbsp;·&nbsp; Telegram &nbsp;·&nbsp; WhatsApp &nbsp;·&nbsp; CLI
</p>

> **Why "Pepe"?** The name nods to Chespirito's comedy universe, loved across
> Latin America generations grew up with. The character's whole thing? **He
> did exactly what he was told.** No arguing, no improvising beyond the
> order. Which, funnily enough, describes an AI agent runtime perfectly.
> The project was once called *Cortex*; now it's **Pepe**. Same engine, better name. 🫡

**Pepe is an Elixir/OTP AI agent runtime.** Define agents, connect to any model, and
run a tool-calling loop. It leans on what Elixir is good at: a lightweight process per
conversation (so many run side by side), supervision that isolates crashes (one
conversation failing never takes the rest down), and a small streaming HTTP stack.

It exposes those core capabilities several ways:

| Surface | Endpoint | Use it for |
|---|---|---|
| **Web dashboard** | `GET /` (Phoenix LiveView) | Browse sessions and chat from the browser |
| **OpenAI-compatible HTTP** | `POST /v1/chat/completions`, `GET /v1/models` | Point any OpenAI SDK / LangChain / `curl` at Pepe |
| **WebSocket** | `ws://.../socket/websocket`, topic `agent:<name>` | Live, token-streamed conversations |
| **Telegram** | a Telegram bot | Chat with your agent from your phone |
| **Terminal console** | `mix pepe tui` | An interactive console that remembers the conversation |
| **CLI** | `mix pepe ...` | Create agents & model connections, run, serve |

Everything talks to providers over the **OpenAI Chat Completions** protocol, so
OpenAI, OpenRouter, Together, Groq, DeepSeek,
Mistral, z.ai/GLM, Kimi/Moonshot, MiniMax, NovitaAI, Ollama, LM Studio, vLLM,
llama.cpp and any other compatible endpoint work with zero code changes.

---

## Quick start

```bash
mix deps.get

# 1) scaffold ~/.pepe/config.json
mix pepe setup

# 2) add a model connection (any OpenAI-compatible provider; openrouter is a
#    known provider, so its base URL is filled in automatically)
mix pepe model add openrouter --api-key '${OPENROUTER_API_KEY}' --model openai/gpt-5-chat

# 3) define an agent (defaults to all built-in tools; the first model/agent
#    you add becomes the default automatically)
mix pepe agent add assistant --prompt "You are Pepe, a helpful coding agent."

# 4) run it
export OPENROUTER_API_KEY=sk-...
mix pepe run "list the files here and summarize the project"
```

## Documentation

One topic per page - open just what you need.

**Get going** &nbsp; [Architecture](docs/architecture.md) · [CLI reference](docs/cli-reference.md) · [Configuration](docs/configuration.md) · [Migrating from another runtime](docs/migrating.md)

**Talk to it** &nbsp; [Web dashboard](docs/dashboard.md) · [Dashboard auth](docs/authentication.md) · [HTTP API](docs/http-api.md) · [WebSocket](docs/websocket.md) · [Telegram](docs/telegram.md) · [WhatsApp](docs/whatsapp.md) · [Channels (Slack/Discord/Teams/Chat)](docs/channels.md)

**Agents** &nbsp; [Admin agents](docs/admin-agents.md) · [Permissions](docs/permissions.md) · [Agent-to-agent routing](docs/routing.md) · [Companies](docs/companies.md) · [Skills](docs/skills.md) · [Learning](docs/learning.md) · [Goals & plans](docs/goals-and-plans.md) · [Adding a tool](docs/adding-a-tool.md) · [Plugins](docs/plugins.md) · [Self-management](docs/self-management.md)

**Automation & ops** &nbsp; [MCP servers](docs/mcp.md) · [Scheduled tasks](docs/scheduled-tasks.md) · [Watches](docs/watches.md) · [Usage & billing](docs/billing.md) · [Traces](docs/traces.md) · [Evals](docs/evals.md) · [Privacy hooks](docs/privacy-hooks.md)

**Contribute** &nbsp; [Contributing & help wanted](docs/contributing.md) · [Tests](docs/tests.md)


---

## Put it in your product

Pepe is meant to be embedded. A few common paths:

- **Behind your web app / SaaS** - point any OpenAI SDK at the [HTTP API](docs/http-api.md), scope access with per-company [tokens](docs/http-api.md), and keep tenants isolated with [Companies](docs/companies.md).
- **Customer support on WhatsApp** - connect a number and bind it to a support agent; see [WhatsApp](docs/whatsapp.md). Redact PII before it reaches any model with [Privacy hooks](docs/privacy-hooks.md).
- **Bill your clients** - every model call is metered per company; export invoices from [Usage & billing](docs/billing.md).
- **Automate** - recurring jobs with [Scheduled tasks](docs/scheduled-tasks.md), one-shot "notify me when X" with [Watches](docs/watches.md).

---

## Contributing - help wanted 🙌

Pepe is young and **help is genuinely welcome** - bug reports, docs fixes, features,
and especially **confirming providers work**. Small, focused PRs are the easiest to
review and merge.

Get set up in a minute (no database, no API keys needed for the test suite):

```bash
git clone https://github.com/jhonathas/pepe.git && cd pepe
mix deps.get
mix test          # the whole suite, over real TCP - no DB, no keys
```

Then fork, branch off `master`, make your change (match the style in `AGENTS.md`),
run `mix precommit`, and open a PR against `master`. Adding a tool? Follow
[Adding a tool](docs/adding-a-tool.md).

**The single most useful thing you can do:** I run Pepe day-to-day on one setup
(the ChatGPT/Codex OAuth subscription), so most providers are unverified. If you use
OpenRouter, Groq, DeepSeek, Together, Mistral, Ollama, LM Studio, the Claude Pro/Max
sign-in, or anything else - run `mix pepe model test`, try one prompt, and open an
issue saying whether **streaming** and **tool-calling** worked. That feedback is worth
a lot.

Full guide, including everything that needs testing: [Contributing & help wanted](docs/contributing.md).
