# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-04-20

First public release.

**Pepe is an Elixir/OTP AI agent runtime.** You define agents, connect them to
any OpenAI-compatible model provider, and Pepe runs the tool-calling loop. It
leans on what Elixir is good at: a lightweight process per conversation (so many
run side by side), supervision that isolates crashes, and a small streaming HTTP
stack. No database - configuration lives in a JSON file, working state in Mnesia.

### Added

#### Core runtime

- Agent runtime with a tool-calling loop: call the model, run the requested
  tools, feed results back, repeat until a final answer or `max_iterations`.
- Stateless one-shots and keyed, persistent sessions - one supervised process
  per conversation, so a crash in one never touches another.
- Connect to any OpenAI-compatible endpoint with no code changes - OpenAI,
  OpenRouter, Groq, DeepSeek, Mistral, Together, z.ai/GLM, Kimi, Ollama,
  LM Studio, vLLM and more.
- Streaming responses (SSE) with assembled tool calls, plus non-streaming.
- Model failover and routing: send different agents or requests to different
  models, with fallbacks when a provider is down.

#### Built-in tools

- Shell: `bash` and `run_script`, with guardrails and an optional sandbox.
- Files: read, write, edit, move, and list directories.
- Web: `fetch_url` and `web_search`.
- Messaging: send files back to a chat, and agent-to-agent messaging.
- Self-management (guarded): read own docs, run diagnostics, get/set config,
  enable tools, manage agents, channels, tokens, MCP servers, plugins, skills
  and scheduled tasks - each behind a permission gate.

#### Ways to talk to it

- **CLI** - `pepe run`, `pepe chat`, and a guided `pepe setup`, with `help` for
  every command group.
- **OpenAI-compatible HTTP API** - `POST /v1/chat/completions`, `GET /v1/models`;
  point any OpenAI SDK at it.
- **WebSocket** - live, token-streamed conversations over a Phoenix channel.
- **Web dashboard** (Phoenix LiveView) - chat, inspect traces, and manage
  models, agents, channels, tokens and scheduled work; optional password gate.
- **Channels** - Telegram and WhatsApp, plus Slack, Discord, Microsoft Teams and
  Google Chat over a single generic webhook route, with an admin/support mode
  and session TTLs.

#### Multi-tenant & operations

- **Companies** - optional tenant isolation: agents, workspaces, shared config,
  models and routing walled off per tenant (a root default when unused).
- **API tokens** - scoped tokens per company for the HTTP API.
- **Usage & billing** - token metering per company at the runtime choke point,
  a durable ledger, layered pricing, per-company markup, and invoice export.
- **Scheduled tasks (cron)** - an in-app minute ticker (no OS crontab) with
  catch-up after downtime; created from config or, with a double opt-in, by chat.
- **Watches** - durable one-shot "check X and notify me when it happens",
  delivered back to the originating channel.
- **Skills & learning** - a skill registry the agent can scan and use, plus
  memory that carries across conversations.
- **MCP** - connect external tools over the Model Context Protocol.
- **Privacy hooks** - opt-in PII redaction (built-in and Presidio) before
  anything reaches a model, reversible on the way back.
- **Reliability** - heartbeat, message spill under load, and dead-target
  cleanup.
- **Secret references** - credentials written as `${ENV_VAR}` are interpolated
  at read time and never persisted expanded.

#### Distribution & setup

- **Installer** - `curl -fsSL https://pepe-agent.com/install.sh | sh` drops a
  self-contained `pepe` binary (built with Burrito; macOS, Linux, Windows) into
  `~/.local/bin` - no root, no runtime to install - and wires up your PATH.
- **Service mode** - `pepe serve install` runs the server as a persistent
  launchd/systemd service that survives reboot and restarts on crash.
- **Quick tunnel** - `pepe serve --tunnel` exposes the local server via a
  Cloudflare quick tunnel.
- **Guided, localized setup** - `pepe setup` follows the language you choose
  (en, pt-BR, pt-PT, es) and validates required channel credentials before
  saving a connection.

[Unreleased]: https://github.com/pepe-agent/pepe/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pepe-agent/pepe/releases/tag/v0.1.0
