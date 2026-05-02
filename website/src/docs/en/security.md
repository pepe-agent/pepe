---
title: Security and sandbox
description: Agents run code, so they do real work and can do real damage. Pepe stacks a permission gate, command guardrails, an opt-in sandbox, secret references, redaction hooks, and access control, and is honest about what each one does.
---

## The threat, plainly

An agent that can run a command or write a file is useful precisely because it acts on your machine. That same power is the risk. Pepe does not pretend one setting makes this safe. Instead it stacks several independent protections, each with a clear job, and lets you turn up the strength as your exposure grows. This page walks through every layer, from the one that is always on to the one you opt into for a hard boundary.

The layers, from weakest-but-always-on to strongest-but-opt-in:

1. The permission gate. A human approves any tool that acts.
2. Command guardrails. A built-in filter that refuses a few catastrophic commands.
3. The sandbox. An opt-in wrapper that runs shell commands in real isolation.
4. Secret references. Credentials live as `${ENV_VAR}`, never expanded on disk.
5. Redaction hooks. Optional PII scrubbing before text reaches a model.
6. Access control. The dashboard password and API bearer tokens.

<div class="note"><strong>No single setting is a security boundary by itself.</strong> The honest default is the permission gate plus the guardrails. For anything that runs unattended or auto-approves tools, add the sandbox, and ideally run Pepe as a limited user or inside a container.</div>

## The permission gate

Every tool call passes through a gate before it runs. Read-only tools run freely. Everything that acts (running a command, writing or moving a file, changing config, and any third-party plugin tool) must be authorized first.

The tools that never ask are the read-only ones: `read_file`, `list_dir`, `fetch_url`, `web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill`, and `send_to_agent`. Anything not on that list, including any drop-in plugin tool, is treated as risky and requires approval. That is a deliberately safe default: an unknown tool is assumed to be dangerous.

When a risky tool has not been pre-approved, the runtime asks the person on the other end. Each surface renders that prompt in its own native way (inline buttons in a chat channel, an arrow-key menu in the CLI), but the decision is always one of four:

- `once`: allow just this call, ask again next time.
- `session`: allow for the rest of this conversation. Kept in memory, forgotten when you start a new session or restart. Other sessions still ask.
- `always`: allow from now on. Persisted on the agent in `config.json`.
- `deny`: refuse. Never remembered, so the same call is asked again later.

A denied call does not crash the run. The model is told the user did not authorize the tool and is asked to try another approach or check in with you, so the conversation keeps going.

### Auto-approval and the owner agent

Choosing `always` at the prompt records that tool in the agent's `auto_approve` list, so it never asks again for that agent. There is no separate flag to set this up front from `pepe agent add`. You grant trust either by answering `always` once when the prompt appears, or by editing the agent in `config.json`:

```json
{
  "agents": {
    "ops": {
      "system_prompt": "You keep the build green.",
      "tools": ["bash", "read_file", "write_file"],
      "auto_approve": ["read_file", "write_file"]
    }
  }
}
```

A single wildcard `"*"` in `auto_approve` means the agent runs every tool without ever asking. That is the omnipotent owner agent created for you at `pepe setup`: trusted with all tools so you can drive your own machine without friction. Grant that trust deliberately, and never to an agent exposed to untrusted input.

```json
{
  "agents": {
    "owner": {
      "system_prompt": "...",
      "tools": ["bash", "read_file", "write_file", "edit_file"],
      "auto_approve": ["*"]
    }
  }
}
```

<div class="note"><strong>Surfaces with no human run freely.</strong> The HTTP API has nobody to prompt, so it supplies no approver and risky tools run without asking. Treat the API as fully trusted, and lock it with a token (see below) before exposing it.</div>

### The owner can drive the CLI by chat

The `manage_pepe` tool runs the same non-interactive `pepe` commands you would type in a terminal (add a model, define an agent, mint a token, schedule a task, manage companies), so a trusted owner agent can operate the whole runtime from a conversation.

> You: Add an agent called researcher with the web_search and read_file tools.
>
> Agent: (asks you to confirm, then runs `pepe agent add researcher --tools web_search,read_file`) Done. The researcher agent is ready.

It is the most powerful tool there is. Give it only to an owner agent you fully trust, never to one exposed to untrusted input. Like every acting tool it passes the permission gate, and the interactive or long-running commands (`setup`, `chat`, `serve`, and foreground gateways) are refused because they cannot run as a one-shot. For a single, narrower job, prefer the focused tools: `manage_token` for tokens, `manage_channel` for channels, `schedule_task` for crons.

## Command guardrails

The shell tools (`bash` and `run_script`) run every command through a guard first. The guard refuses a small, deliberately narrow set of catastrophic, never-legitimate operations:

- Recursive deletes of a system path, `/`, `~`, or `$HOME`.
- Formatting a filesystem (`mkfs`).
- Writing raw to or overwriting a disk device (`dd of=/dev/...`, or redirecting into `/dev/sda` and friends).
- Fork bombs.
- Powering off or rebooting the host (`shutdown`, `reboot`, `halt`, `poweroff`, `init 0`).

It is pure, cross-platform, zero-config, and always on. It costs nothing, so it never has to be enabled.

Be clear about what it is: a thin net against accidents and obvious prompt injection, not a security boundary. A determined or obfuscated command can slip past static inspection, and the guard deliberately allows powerful but legitimate work such as installing dependencies or querying a database. For a real boundary, add the sandbox.

## The sandbox (opt-in isolation)

For an actual boundary, so that even an auto-approved agent cannot touch the host, configure a sandbox wrapper. A wrapper is a small executable that Pepe hands each command to. The wrapper runs the command isolated however the host allows, then returns the output. Pepe passes the agent's working directory in the `PEPE_SANDBOX_CWD` environment variable so the wrapper can mount or confine writes to just that directory.

When no wrapper is set (the default), commands run directly on the host and the permission gate is the protection. When a wrapper is set, every shell command goes through it.

The fastest way to set one up is the setup flow, which writes a ready-made wrapper to `~/.pepe/sandbox/` and points the config at it:

```bash
pepe setup
```

Pick the Sandbox step and choose your isolation. Pepe offers what your host supports:

| Host | Options |
|------|---------|
| Linux | firejail (lightweight, namespaces) or Docker/Podman |
| macOS | sandbox-exec (ships with macOS) or Docker Desktop |
| Windows | Docker or WSL |

Docker is the portable common denominator: it mounts only the workspace, so the rest of the host filesystem is invisible, and you can keep the network on when the agent needs a database or an API. The Docker wrapper is tunable through environment variables, including `PEPE_SANDBOX_IMAGE`, `PEPE_SANDBOX_NET` (`bridge` or `none`), `PEPE_SANDBOX_MEM`, `PEPE_SANDBOX_CPUS`, and `PEPE_SANDBOX_RUNTIME` (`docker` or `podman`).

If you would rather point at your own wrapper, set the path directly in `config.json`:

```json
{
  "sandbox": "/Users/you/.pepe/sandbox/docker.sh"
}
```

Any executable works as long as it runs its arguments (`program arg1 arg2 ...`) isolated and honors `PEPE_SANDBOX_CWD`. Setup only warns, and never auto-installs, if the underlying tool (docker, firejail, sandbox-exec) is missing from your `PATH`.

<div class="note"><strong>There is no zero-config, cross-platform true sandbox.</strong> Every real one needs an operating system feature or an external tool. That is why the sandbox is opt-in and the always-on defaults are the gate plus the guardrails. When agents run unattended or auto-approve tools, treat the sandbox as required, not optional.</div>

## Secrets stay as references

Configuration lives in a plain JSON file at `~/.pepe/config.json`. There is no database. To keep credentials out of that file, write them as `${ENV_VAR}` references. Pepe interpolates them against the environment at read time and never persists the expanded value.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

At runtime the real key is read from the environment. On disk the file only ever contains the placeholder. The same mechanism works for gateway tokens, plugin settings, and the dashboard password, so you can commit or share a config without leaking anything. Export the variables before you serve:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

A whole-string placeholder that resolves to nothing (the variable is unset) is treated as "unset" rather than an empty string, so a missing secret surfaces as a clear "not configured" rather than a silent blank.

### Do it by chat

An agent granted the read-only `config_get` and `doctor` tools can report on your setup and catch a missing secret in plain conversation. Both are read-only, so they never trigger the permission gate.

> You: Is everything configured correctly?
>
> Agent: (runs `doctor`) I found one problem: the model connection "openrouter" references `${OPENROUTER_API_KEY}`, but that variable is not set in the environment. Export it before serving.

The `doctor` tool health-checks the whole setup and flags unset `${ENV}` secrets, agents pointing at missing models, invalid schedules, and unreachable connections. Pass `live: true` to also probe the network.

<div class="note"><strong>Security-sensitive settings are not editable by the general config tool.</strong> The guarded `config_set` tool is fail-closed: it only touches a short allowlist (the default model and agent, language, timezone, and a couple of Telegram flags). Secrets, tool allowlists, bot tokens, the sandbox wrapper, and the dashboard password are deliberately off that list, so `config_set` cannot change them. You set those yourself with the CLI or the dashboard. API tokens are the one thing an agent can mint by chat, but only through the separate, permission-gated `manage_token` tool, never through `config_set`.</div>

## Redaction hooks (opt-in PII scrubbing)

If your agents handle personal data, you can scrub it before it ever reaches a model. Redaction hooks run on the message flow and are enabled per agent, so only the agents that need them pay the cost.

```bash
pepe agent add support \
  --prompt "You help customers." \
  --tools read_file \
  --hooks pii_redact
```

Three points in the flow get redacted: the human's inbound message, **any tool's raw output** (a database query, a file read, a web fetch, anything a tool surfaces, not just what a human typed), and the agent's outbound reply. Tool output is redacted before it joins the conversation and before it's ever written to disk, so a large result that gets spilled to a workspace file (see Agents) is spilled already-redacted, never raw. Ask "list the 10 most recent patients with a cardiac diagnosis" against your own database and, with `pii_redact` enabled, the model reasons over `[PERSON_1]`, `[PERSON_2]`, ...; only the final reply back to you gets the real names restored.

Four hooks ship in the box:

- `pii_redact`: an offline, zero-dependency regex redactor. It replaces structured PII (email, card number, and national ids such as CPF or CNPJ) with a stable token like `[CPF_1]`. By default it is reversible: it records `token -> real` so the pipeline can restore the real value in the reply on the way out.
- `llm_redact`: uses a local or configured model to replace names, addresses, and free text with realistic pseudonyms, then restores them on the way out. Best paired with `pii_redact`, which handles structured ids deterministically while the model handles the messy parts in any language.
- `presidio`: sends text through your own self-hosted Microsoft Presidio analyzer and anonymizer containers, so the data stays under your control.
- `http_redact`: the generic escape hatch. Pepe posts the message to your own endpoint, which returns the transformed text, so any redaction service plugs in without a dedicated adapter.

Global settings for each hook (which recognizer packs, custom patterns, whether to keep it reversible) live under `"hooks"` in `config.json`. You can have a model draft a `pii_redact` config for you:

```bash
pepe hooks list
pepe hooks generate "redact Brazilian CPF, emails, and phone numbers" --save
```

The regex and HTTP hooks fail open by design: if a redactor errors or a model is unavailable, the original text passes through rather than blocking work. When you need a hard guarantee, mark the model connection with `require_redaction` in `config.json`. A model flagged that way refuses to run at all unless the agent has at least one redaction hook enabled, turning a best-effort scrub into an enforced one.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini",
      "require_redaction": true
    }
  }
}
```

## Dashboard access

The web dashboard is open on localhost by default, which is convenient for local development. The moment you expose it beyond your machine, put it behind a password:

```bash
pepe dashboard password '${PEPE_DASHBOARD_PASSWORD}'
```

Bound to a public interface with no password, the dashboard fails closed and blocks remote clients until you set one. Full details live on the [Dashboard](../dashboard/) page: the `Host` allowlist and trusted-proxies settings for serving it behind a domain, and running it as a persistent service.

## API tokens

With no token, the HTTP API answers only loopback (localhost) callers, so a local setup stays simple while a network-exposed server is never anonymous. Creating the first token flips it to closed for everyone: from then on every request to `/v1`, local or remote, needs an `Authorization: Bearer` header carrying a valid token. Mint one with:

```bash
pepe token add --label "ci pipeline"
```

The raw token is shown once and only its SHA-256 hash is stored, never the token itself. A token can be scoped: `--company` limits it to one tenant's agents, and `--agent` limits it to a single agent (which must live inside that company). Manage them with `pepe token list` and `pepe token revoke ID`, from the dashboard's API tokens page, or by chat with an agent that has the guarded `manage_token` tool. For request shapes and SDK usage, see the [HTTP API page](../api/).

## Multi-tenant scoping

Work can be walled off per company (a handle-based tenant scope). The default no-company scope is called Principal. A company's agents, models, and provider keys stay invisible to other companies, and an API token scoped to a company reaches only that company's agents. This keeps one tenant's credentials and conversations from ever leaking into another's, which matters when you host agents on behalf of several customers from one Pepe instance.
