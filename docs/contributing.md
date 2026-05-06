# Contributing & help wanted

Pepe is young and help is very welcome: bug reports, provider confirmations, docs
fixes, and features. Small, focused PRs are the easiest to review and merge.

### Set up for development

You need **Elixir ~> 1.15** and Erlang/OTP (install via [asdf](https://asdf-vm.com/)
or your package manager). **No database is required**; the test suite starts its own
local mock model server, so there's nothing to provision.

```bash
git clone https://github.com/pepe-agent/pepe.git pepe && cd pepe
mix deps.get
mix test          # runs the whole suite over real TCP - no DB, no API keys
```

Only if you want to open the **dashboard** locally:

```bash
mix assets.setup && mix assets.build
mix pepe serve                     # http://localhost:4000
```

### Open a pull request

1. **Fork** the repo, then branch off `master`:
   `git checkout -b fix-telegram-retry`.

2. **Make your change.** Match the surrounding style; the detailed conventions live in
   **`AGENTS.md`** (HTTP client, immutability, one module per file, `?`-suffixed
   predicates, ...). A new tool follows the `Pepe.Tools.Tool` behaviour, see
   [**Adding a tool**](adding-a-tool.md).

3. **Run the full check** before pushing. It must pass (it's the same gate a
   reviewer applies):

   ```bash
   mix precommit    # compile (warnings = errors) + unused-deps check + format + tests
   ```

4. **Push to your fork and open a PR** against `master`. Say what changed and why, and
   link an issue if there is one. Please include a test for new behaviour and a line
   in this README for anything user-facing.

### What needs testing (help especially wanted here)

I've been running Pepe day-to-day on a **single** setup: the ChatGPT/Codex OAuth
**subscription** model. Everything speaks the same OpenAI protocol, so the rest
*should* work unchanged, but I genuinely haven't verified it. If you can confirm (or
break) any of the below, please open an issue with what you tried and what happened:

- **Model providers** - API-key connections to OpenRouter, Groq, DeepSeek, Together,
  Mistral, z.ai/GLM, Kimi/Moonshot, MiniMax, NovitaAI, and local runtimes (Ollama, LM
  Studio, vLLM, llama.cpp). Ideally both **streaming** and **tool-calling** on each.

- **The Claude Pro/Max OAuth sign-in** - only the ChatGPT/Codex flow has been exercised.

- **Surfaces & features** - Telegram (single and multi-bot), the WebSocket API with
  access tokens, company isolation, usage metering & invoices, cron, watches, and MCP
  servers against a real server.

The most useful quick report: your provider, the output of `mix pepe model test`, and
one prompt run: did the reply **stream**, and did a **tool call** work?

---

[Back to the docs index](../README.md#documentation)
