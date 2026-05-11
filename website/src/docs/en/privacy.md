---
title: Privacy hooks (PII redaction)
description: Opt-in transforms plugged into the message flow, so an agent can redact personal data before it ever reaches an external model, and restore it in the reply.
---

Privacy hooks are opt-in transforms plugged into the message flow, so an agent can redact PII before it ever reaches an external model, and restore it in the reply. An agent with no hooks runs raw, exactly as before.

You enable them per agent (with `--hooks`, or the Agents form in the dashboard), you can inherit a company default (`default_hooks`), and you configure each hook once under `"hooks"` in the config.

## Four hooks, one contract

They compose, because each one feeds the same reversible map:

- **`pii_redact`**: offline regex. Recognizers (email, card via Luhn, CPF/CNPJ with checksums, CEP, phones) grouped into packs (`intl`, `br`, `us`), plus your own `custom` `{name, pattern, replace}`. It tokenizes structured PII and restores it on the way out.
- **`llm_redact`**: a configured or local model replaces PII with realistic pseudonyms and returns a `fake -> real` map, kept consistent across turns. It handles names and free text that the regex cannot, in any language, and keeps the data off the main model.
- **`http_redact`**: your own endpoint decides. Pepe POSTs `{stage, text, session, map}`; you return `{text, map}`. Auth via `basic_auth` or arbitrary `headers` (all `${ENV}`).
- **`presidio`**: Microsoft Presidio's Analyzer and Anonymizer over HTTP (self-hosted).

## Using them

```bash
pepe agent add support --hooks pii_redact,llm_redact --company acme --prompt "..."
pepe hooks list
# let a model build a validated pii_redact config from plain language:
pepe hooks generate "cpf, cnpj and our policy numbers APOL-12345678" --model local --save
```

## A hard guarantee

Mark a model connection **require_redaction** and the runtime refuses to send to it unless the agent runs a redaction hook, so a forgotten agent config can never leak raw PII to that provider.

<div class="note"><strong>Redaction runs off-process.</strong> An LLM-backed hook never blocks the session. The reversible map lives only in memory, and it is cleared on reset, on <code>end_session</code>, and on TTL eviction.</div>

The wider picture, including where in the flow the redaction happens and how it interacts with the permission gate, is on the [Security](../security/) page.
