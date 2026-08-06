---
title: Privacy hooks (PII redaction)
description: Have an agent strip personal data out of messages before they ever reach an external model, and put the real values back in the reply. Off by default, enabled per agent.
---

Privacy hooks let an agent scrub personal data (PII: names, emails, document numbers) out of the message flow before anything reaches an external model, and put the real values back in the reply. They are opt-in: an agent with no hooks runs raw, exactly as before.

You enable them per agent (with `--hooks`, or the Agents form in the dashboard), you can inherit a project default (`default_hooks`), and you configure each hook once under `"hooks"` in the config.

## Four hooks, one contract

You can combine them, because they all feed the same reversible map: the record of what was replaced by what, used to restore the real values on the way out.

- **`pii_redact`**: pattern matching (regex) that runs entirely on your machine, nothing is sent anywhere. Recognizers (email, card via Luhn, CPF/CNPJ with checksums, CEP, phones) grouped into packs (`intl`, `br`, `us`), plus your own `custom` `{name, pattern, replace}`. It replaces structured PII with tokens and restores it on the way out.
- **`llm_redact`**: a configured or local model replaces PII with realistic pseudonyms and returns a `fake -> real` map, kept consistent across turns. It handles names and free text that the regex cannot, in any language, and keeps the data off the main model.
- **`http_redact`**: your own endpoint decides. Pepe POSTs `{stage, text, session, map}`; you return `{text, map}`. Auth via `basic_auth` or arbitrary `headers` (all `${ENV}`).
- **`presidio`**: Microsoft Presidio's Analyzer and Anonymizer over HTTP (self-hosted).

## Using them

```bash
pepe agent add support --hooks pii_redact,llm_redact --project acme --prompt "..."
pepe hooks list
# let a model build a validated pii_redact config from plain language:
pepe hooks generate "cpf, cnpj and our policy numbers APOL-12345678" --model local --save
```

## A hard guarantee

Mark a model connection **require_redaction** and the runtime refuses to send to it unless the agent runs a redaction hook, so a forgotten agent config can never leak raw PII to that provider.

<div class="note"><strong>Redaction never holds up the conversation.</strong> An LLM-backed hook runs alongside the session, not inside it (off-process), so it never blocks a reply. The reversible map lives only in memory, and it is cleared on reset, on <code>end_session</code>, and on TTL eviction.</div>

The wider picture, including where in the flow the redaction happens and how it interacts with the permission gate, is on the [Security](../security/) page.
