# Privacy hooks - redact PII before it reaches a model

Hooks are opt-in transforms plugged into the message flow. When an agent has hooks,
its incoming text is **redacted before it ever reaches an external model**, and the
real values are restored in the reply. An agent with no hooks runs raw, exactly as
before. You do **not** call hooks as a chat tool - they're attached to an agent's
config and run automatically on every surface (Telegram, WhatsApp, API, console).

## The four hooks

All four share one contract and feed the same reversible map, so they compose:

- **`pii_redact`** - offline regex, zero dependencies, the default. Recognizers
  (email, card via Luhn, CPF/CNPJ with checksums, CEP, phones) grouped into packs
  (`intl`, `br`, `us`) plus your own `custom` `{name, pattern, replace}`. Replaces
  each match with a stable token (`[CPF_1]`) and restores it on the way out.
- **`llm_redact`** - a configured/local model (`model` setting, required) swaps PII
  for realistic pseudonyms and returns a `fake -> real` map, kept consistent across
  turns. Handles names and free text the regex can't, in any language. Fail-open.
- **`http_redact`** - your own endpoint decides. Pepe POSTs
  `{stage, text, session, map}`; you return `{text, map}`. One `url` or separate
  `inbound_url`/`outbound_url`; auth via `basic_auth` or arbitrary `headers` (all
  `${ENV}`-interpolated).
- **`presidio`** - Microsoft Presidio's Analyzer + Anonymizer over HTTP, self-hosted
  (`analyzer_url` + `anonymizer_url` required).

Best pairing: `pii_redact` for structured ids (deterministic) plus `llm_redact` for
names/addresses/free text. The regex tokens and the pseudonyms both restore out.

## The reversible map

Reversible hooks record `token/pseudonym -> real value` as text flows in, then put the
real values back on the way out - so the user sees natural text, the external model
never sees raw PII. The map lives **only in memory** and is cleared on reset,
`end_session`, or TTL eviction. Redaction runs off-process, so an LLM-backed hook
never blocks the session.

## The hard guarantee (`require_redaction`)

Mark a model connection **`require_redaction`** and the runtime **refuses to send to
it** unless the agent runs a redaction hook - so a forgotten agent config can never
leak raw PII to that provider. Use it when a provider must never see plaintext PII.

## How to configure and enable a hook

Hooks are set on the agent's config and configured once under `"hooks"` in
`~/.pepe/config.json` - not from a chat tool (`config_set` is fail-closed and won't
touch them). Enable them one of these ways:

- per agent at creation - `mix pepe agent add support --hooks pii_redact,llm_redact`
  (or the dashboard Agents form),
- a company-wide default - `default_hooks`,
- and configure each hook's settings under `"hooks"` in the config file.

Two CLI helpers:

```bash
mix pepe hooks list       # the registered hooks + where settings live
# let a model build a validated pii_redact config from plain language:
mix pepe hooks generate "cpf, cnpj and our policy numbers APOL-12345678" --model local --save
```

`hooks generate` asks a model to build a `pii_redact` config (packs + custom regex),
validates every pattern, and (with `--save`) writes it to `hooks.pii_redact`. If the
user wants a specific PII policy, that's the fastest way to a working config - then
enable the hook on the agent.
