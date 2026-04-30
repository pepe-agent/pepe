# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Dashboard: a live **runtime footprint** on the overview (memory, CPU, open conversations, processes, uptime) and, per agent, how many conversations it has open and what they hold. "Lightweight by design" is now a number you can check rather than a claim: CPU comes from the scheduler counter and reads `-` until it can be known, never a fabricated zero.
- Dashboard: the complexity-routing box now names the model each branch uses, including the complex one (the agent's own), so the whole route reads without scrolling back up.

### Fixed
- Goals: the loop's prompts appear as messages in the conversation, so they are now written in the configured language instead of always English.
- Chat: a goal loop's retry turns appeared only after a page reload. The runtime emits `:done` before the session commits the turn, so the history read at that moment could be one turn behind and the new answer was silently dropped; the view now re-syncs from the session, which is the source of truth.

### Added
- Goals: run an agent **toward an outcome** instead of for one turn. Give it an objective and a verifiable success criterion, and it works, has an **independent reviewer** (a separate model call that sees only the criterion and the result, never the working conversation) check whether the criterion is met, and retries with the reviewer's feedback until it passes or a mandatory attempt cap is reached. `pepe goal "OBJECTIVE" --criteria "how we know it's done" [--max-attempts N] [--judge MODEL]` on the CLI, and `/goal <objective> | <criterion>` on the dashboard, where the panel above the chat shows the criterion, the attempt count and the reviewer's last verdict live.

### Changed
- HTTP API: server-side sessions now key on two dimensions - the standard OpenAI `user` (who) and `session_id`/`X-Session-Id` (which conversation). Both given → `user:session_id` (independent threads per user, e.g. a WhatsApp number with several threads); one given → that value alone; the same value in both → deduped; neither → stateless. A plain OpenAI SDK, which only sends `user`, keeps a conversation with no Pepe-specific field.

### Added
- Commands: `/retry` redoes the last answer (drops the last exchange and re-sends your message) on the dashboard, Telegram, and CLI; `/usage` shows this month's spend and message count for the conversation's company (operator-only on Telegram: gated to the bot's `trainers` so a client on a customer-facing bot never sees billing); `/name <text>` labels a conversation in the dashboard sidebar (persisted), and a fork is auto-labeled after its source so branches are easy to tell apart.
- Dashboard: `/fork` branches the current conversation into a new session seeded with a copy of its history, then switches to the branch, so you can explore a different direction without losing where you were. The original stays live in the sidebar to return to. Dashboard only (it relies on the session sidebar to switch and label branches).
- Sessions: a message sent while a turn is running now queues and runs right after it (FIFO), instead of being rejected as busy, so nothing is dropped when you fire off a few messages in a row. Its reply still lands with the caller when its turn comes up. New `/inline <text>` command folds a message into the turn already running (the agent picks it up before its next step) for when you want to steer it now rather than wait; on the dashboard and Telegram.
- Update: `pepe update` self-updates the binary to the latest release (downloads the build for your OS/arch, swaps it in place, keeps the old one as a backup). Also on the dashboard (a "Check for updates" button on the config page that becomes "Update to vX" with a link to the release notes) and by chat. From a source checkout it points you at `git pull` instead.
- Approvals: autonomous writes can be gated for review. With `review_writes` on, memory/skill consolidation stages its file changes instead of applying them, and you approve or reject each from the CLI (`pepe review`), the dashboard (Learning page), or by chat (the `review` tool), so a hallucinated fact or a bad skill edit never persists silently. Off by default.
- Runtime: long conversations are condensed automatically to stay under the model's context window. Once the history grows large, older turns are summarized by the model while the system prompt and recent turns are kept verbatim, so an agent can run indefinitely without a manual reset (the full transcript is still kept in traces). The manual `/compact` command now shares this single engine.

### Fixed
- Telegram: operator-only commands are now gated to the bot's `trainers` (like `/usage`), so a client on a customer-facing bot can't reach them or see internals: `/approve` (tool-permission grants), `/agent` (switch agent), `/status` and `/model` (reveal the agent/model), `/models`, `/tools`, and `/skill` (list/run). Switching the model was already permission-gated. Personal bots (no `trainers` list) are unaffected.
- Dashboard: the overview's counts (live sessions, channels, automations) and the API tokens list now respect the selected company, instead of always showing totals across every workspace.
- Runtime: a conversation resumed after a crash mid-tool-call no longer loops. Any tool call the model requested but never got an answer for is dropped from the replayed history instead of being re-issued forever.
- Runtime: an agent that keeps issuing the exact same tool call with no progress now stops and summarizes what it found, instead of spinning to the iteration limit.

### Added
- Setup: `pepe setup` now shows where config and data are stored and lets you relocate it (sets `PEPE_HOME` and offers to persist it to your shell profile), and prints a "where everything lives" summary at the end.
- Setup: auto-backs up your config before changing it (keeping the last few), and the installer snapshots your config on an update.
- First run: `pepe run` / `pepe chat` with no model configured offers to run setup right there (or says what to run when there's no terminal).
- Output: file paths are shortened to `~/.pepe` (or `$PEPE_HOME`) in setup and diagnostics.
- Dashboard: sign in to a ChatGPT or Claude subscription (or reconnect an existing one) straight from the Models page via a browser OAuth flow that captures the token, no CLI needed.
- Doctor: broader health checks. Adds a security audit (plaintext secrets in config, missing dashboard password), an update check against the latest GitHub release, channel/webhook config validation (provider, agent, required credentials), orphan agent directories on disk, and plugins/skills that won't load.
- README: quick links to the website, documentation, and quickstart near the top.
- README: two quick-start paths, install-and-use (the `pepe` binary via the installer) and from-source (`mix`) for development.

### Fixed
- Docs/website: repository links (clone URL, contributing guide, site nav/footer, JSON-LD) now point at `pepe-agent/pepe` instead of the old `jhonathas/pepe`.

## [0.2.0] - 2026-04-24

### Added
- Tunnel: `pepe serve --tunnel` can now open a named Cloudflare tunnel with a stable URL you choose, via `--token <TOKEN>` (headless) or `--hostname <HOST>` (after `cloudflared tunnel login`); with no options it stays a random quick tunnel.

### Changed
- Dashboard: clearer pt-PT label for the monthly-usage reset button ("repor" is now "reiniciar").
- Website: homepage feature grid expanded to nine cards (added spend & message caps and learning & memory) and reordered from simplest to most advanced.

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

[Unreleased]: https://github.com/pepe-agent/pepe/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/pepe-agent/pepe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pepe-agent/pepe/releases/tag/v0.1.0
