# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-05-01

### Security
- Telegram: operator commands are gated to the bot's `trainers`, so a client on a customer-facing bot cannot reach them or see internals: `/approve` (tool-permission grants), `/agent`, `/status`, `/model` (showing it), `/models`, `/tools`, `/skill`, and `/usage` (billing). They are no longer advertised in `/help` or in the "/" menu either, since inviting a client to try a command they will be refused serves nobody. The gate lives at the one point every command is dispatched from, rather than being repeated inside each: a skill also becomes a top-level command, so `/skill install-tool` and `/install-tool` were two doors to the same room, and only the first was locked. Personal bots (no `trainers` list) are unaffected.
- Update: `pepe update` now verifies the download against a `SHA256SUMS` file published with the release, and refuses to install an asset whose checksum is missing, unreadable, or does not match. Releases publish that file.
- Docker: `/tools` is appended to the `PATH` instead of being prepended. The agent can write there, so a prepended `/tools` would have let it drop a file named `git` or `curl` in front of the real ones and have every later shell command run that instead.
- Dependencies: patched Plug, Phoenix, Mint, hpax, Postgrex and Swoosh (four advisories rated high, including a quadratic-time query-parameter parser reachable through the HTTP API), and moved the website off an Astro release with five XSS advisories.

### Added
- Voice: a voice note now arrives as **text**, transcribed at the door rather than handed to the agent as a file to puzzle over. If a connection you already have serves transcription (OpenAI, Groq), nothing needs configuring: send a voice note and it works. Point `media.audio.model` at any connection to choose one, or set `media.audio.command` (`whisper-cli -f {file}`) to keep audio on the machine. Because the words exist before routing runs, a slash command spoken out loud runs, and in a group the bot can be addressed by voice, neither of which was possible while the transcript only appeared inside the turn. `media.audio.echo` sends the transcript back to the chat so the speaker can see what was heard. With no route available at all, the old behavior remains as the safety net: the agent gets the file and works it out.
- Docker: `docker pull ghcr.io/pepe-agent/pepe`. The same release tag now publishes a container image alongside the binaries, built for `amd64` and `arm64` on native runners (no QEMU), so a pull resolves to the right one on an M-series Mac or a server. Inside the image it is a plain OTP release, not the Burrito binary: in a container the OS is already decided, so bundling an ERTS per OS again is dead weight.
- Docker: the agent runs non-root and so cannot `apt install`, but root was never the missing key, since anything `apt` installs writes to the container layer and dies with the container regardless. Persistence is what matters, so **the agent's home directory is on a volume**: installers write to `~/.local/bin` and `~/.cache` without asking where your volume is, and now those land somewhere that survives. An agent asked to transcribe a voice message installs `uv` and pulls a Whisper model once (27 seconds), and a brand new container reuses both (1.2 seconds). Two volumes, kept apart on purpose: `/data` is state and is what you back up, while `/tools` (the home, plus anything on the `PATH`) is regenerable and architecture-specific, which is exactly what a backup should not carry.
- Docker: `ffmpeg` is deliberately **not** in the image, and the image is 408 MB rather than 945 MB because of it, so a `docker pull` fetches roughly 84 MB per architecture instead of 240 MB. It looked like the one system package the media path needed, since Telegram sends voice as OGG/Opus, but neither route that actually transcribes touches it: a transcription API takes the `.ogg` as it arrives, and `faster-whisper` decodes through PyAV, which carries its own codecs in the wheel (verified on a clean Debian with no ffmpeg installed). Only the opt-in `whisper.cpp` CLI shells out to it, and Debian's package drags in 204 packages and 121 MB of archives (LLVM, Mesa, a speech synthesizer, a theorem prover) to serve a GPU video stack a headless container never touches. If you need it, `PEPE_IMAGE_APT_PACKAGES` installs it, or a static single-file build goes in `/tools`.
- Docker: `--build-arg PEPE_IMAGE_APT_PACKAGES="postgresql-client imagemagick"` installs extra system packages without writing a Dockerfile of your own. Deriving an image still works for anyone who prefers to keep one.
- Dashboard: a live **runtime footprint** on the overview (memory, CPU, open conversations, processes, uptime) and, per agent, how many conversations it has open and what they hold. "Lightweight by design" is now a number you can check rather than a claim: CPU comes from the scheduler counter and reads `-` until it can be known, never a fabricated zero.
- Dashboard: the complexity-routing box now names the model each branch uses, including the complex one (the agent's own), so the whole route reads without scrolling back up.
- Goals: run an agent **toward an outcome** instead of for one turn. Give it an objective and a verifiable success criterion, and it works, has an **independent reviewer** (a separate model call that sees only the criterion and the result, never the working conversation) check whether the criterion is met, and retries with the reviewer's feedback until it passes or a mandatory attempt cap is reached. `pepe goal "OBJECTIVE" --criteria "how we know it's done" [--max-attempts N] [--judge MODEL]` on the CLI, and `/goal <objective> | <criterion>` on the dashboard, where the panel above the chat shows the criterion, the attempt count and the reviewer's last verdict live.
- Commands: `/retry` redoes the last answer (drops the last exchange and re-sends your message) on the dashboard, Telegram, and CLI; `/usage` shows this month's spend and message count for the conversation's company (operator-only on Telegram: gated to the bot's `trainers` so a client on a customer-facing bot never sees billing); `/name <text>` labels a conversation in the dashboard sidebar (persisted), and a fork is auto-labeled after its source so branches are easy to tell apart.
- Dashboard: `/fork` branches the current conversation into a new session seeded with a copy of its history, then switches to the branch, so you can explore a different direction without losing where you were. The original stays live in the sidebar to return to. Dashboard only (it relies on the session sidebar to switch and label branches).
- Sessions: a message sent while a turn is running now queues and runs right after it (FIFO), instead of being rejected as busy, so nothing is dropped when you fire off a few messages in a row. Its reply still lands with the caller when its turn comes up. New `/inline <text>` command folds a message into the turn already running (the agent picks it up before its next step) for when you want to steer it now rather than wait; on the dashboard and Telegram.
- Update: `pepe update` self-updates the binary to the latest release (downloads the build for your OS/arch, swaps it in place, keeps the old one as a backup). Also on the dashboard (a "Check for updates" button on the config page that becomes "Update to vX" with a link to the release notes) and by chat. From a source checkout it points you at `git pull` instead.
- Approvals: autonomous writes can be gated for review. With `review_writes` on, memory/skill consolidation stages its file changes instead of applying them, and you approve or reject each from the CLI (`pepe review`), the dashboard (Learning page), or by chat (the `review` tool), so a hallucinated fact or a bad skill edit never persists silently. Off by default.
- Runtime: long conversations are condensed automatically to stay under the model's context window. Once the history grows large, older turns are summarized by the model while the system prompt and recent turns are kept verbatim, so an agent can run indefinitely without a manual reset (the full transcript is still kept in traces). The manual `/compact` command now shares this single engine.
- Setup: `pepe setup` now shows where config and data are stored and lets you relocate it (sets `PEPE_HOME` and offers to persist it to your shell profile), and prints a "where everything lives" summary at the end.
- Setup: auto-backs up your config before changing it (keeping the last few), and the installer snapshots your config on an update.
- First run: `pepe run` / `pepe chat` with no model configured offers to run setup right there (or says what to run when there's no terminal).
- Output: file paths are shortened to `~/.pepe` (or `$PEPE_HOME`) in setup and diagnostics.
- Dashboard: sign in to a ChatGPT or Claude subscription (or reconnect an existing one) straight from the Models page via a browser OAuth flow that captures the token, no CLI needed.
- Doctor: broader health checks. Adds a security audit (plaintext secrets in config, missing dashboard password), an update check against the latest GitHub release, channel/webhook config validation (provider, agent, required credentials), orphan agent directories on disk, and plugins/skills that won't load.
- README: quick links to the website, documentation, and quickstart near the top.
- README: two quick-start paths, install-and-use (the `pepe` binary via the installer) and from-source (`mix`) for development.

### Changed
- HTTP API: server-side sessions now key on two dimensions - the standard OpenAI `user` (who) and `session_id`/`X-Session-Id` (which conversation). Both given → `user:session_id` (independent threads per user, e.g. a WhatsApp number with several threads); one given → that value alone; the same value in both → deduped; neither → stateless. A plain OpenAI SDK, which only sends `user`, keeps a conversation with no Pepe-specific field.

### Fixed
- Telegram: a bot could lose track of its own name and then talk over every group it was in. The gateway learns its `@username` from `getMe` and treats "I don't know my name" as "assume I was addressed", which is the right way to fail. But a failed lookup was cached alongside a successful one, so a single network blip at startup made that permanent: the mention requirement stopped applying to any group, for the life of the process, until someone restarted it. Only a successful lookup is remembered now, and a failed one is retried on the next message.
- Translations: the Spanish and European Portuguese dashboards were roughly a third wrong or untranslated, and Brazilian Portuguese had 27 stale entries. Because Gettext renders a translation still marked as needing review, the wrong text was on screen rather than falling back to English: the Spanish "Sign out" button read "entrada + salida", "Installed" read "not allowed", and several strings had lost the placeholder that carries the value. All four languages are now complete, reviewed, and checked for placeholder drift.
- Docs: the HTTP API and WebSocket pages documented a token prefix (`ctx_`) that no longer exists, left over from the rename, so a copied example built a client that could not authenticate. The API reference also claimed the API is open until you create the first token, which is not what the code does: without tokens only loopback callers are let in and a remote caller gets a 401.
- Media: transcribing a voice message no longer litters the working directory. The instructions handed to the agent suggested the `whisper` CLI, which writes five transcript files next to itself as a side effect; they now prefer a transcription API when one is configured (a second, no install), fall back to `faster-whisper` printing to stdout, and say so.
- Chat: a dropped connection no longer loses what you had typed. The message box had no id, which is what LiveView needs to recover a form after a reconnect.
- Goals: the loop's prompts appear as messages in the conversation, so they are now written in the configured language instead of always English.
- Chat: a goal loop's retry turns appeared only after a page reload. The runtime emits `:done` from inside the run, before the session has absorbed the turn, so a view that re-read history on that event could read it one turn stale. Sessions now emit `:committed` once the turn is actually in their state, and the view reconciles on that instead of on a timer.
- Dashboard: the overview's counts (live sessions, channels, automations) and the API tokens list now respect the selected company, instead of always showing totals across every workspace.
- Runtime: a conversation resumed after a crash mid-tool-call no longer loops. Any tool call the model requested but never got an answer for is dropped from the replayed history instead of being re-issued forever.
- Runtime: an agent that keeps issuing the exact same tool call with no progress now stops and summarizes what it found, instead of spinning to the iteration limit.
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

[Unreleased]: https://github.com/pepe-agent/pepe/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/pepe-agent/pepe/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/pepe-agent/pepe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pepe-agent/pepe/releases/tag/v0.1.0
