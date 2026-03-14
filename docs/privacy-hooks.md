# Privacy hooks (PII redaction)

Opt-in transforms plugged into the message flow, so an agent can redact PII before
it ever reaches an external model, and restore it in the reply. An agent with no
hooks runs raw, exactly as before. Enable per agent (`--hooks`, or the Agents form),
inherit a company default (`default_hooks`), and configure each hook once under
`"hooks"` in the config.

Four hooks, one contract, so they compose (each feeds the same reversible map):

- **`pii_redact`** - offline regex: recognizers (email, card via Luhn, CPF/CNPJ with
  checksums, CEP, phones) grouped into packs (`intl`, `br`, `us`) plus your own
  `custom` `{name, pattern, replace}`. Tokenizes structured PII and restores it out.

- **`llm_redact`** - a configured/local model replaces PII with realistic pseudonyms
  and returns a `fake -> real` map, kept consistent across turns. Handles names and
  free text the regex can't, in any language, and keeps the data off the main model.

- **`http_redact`** - your own endpoint decides. Pepe POSTs
  `{stage, text, session, map}`; you return `{text, map}`. Auth via `basic_auth` or
  arbitrary `headers` (all `${ENV}`).

- **`presidio`** - Microsoft Presidio's Analyzer + Anonymizer over HTTP (self-hosted).

```bash
mix pepe agent add support --hooks pii_redact,llm_redact --company acme --prompt "..."
mix pepe hooks list
# let a model build a validated pii_redact config from plain language:
mix pepe hooks generate "cpf, cnpj and our policy numbers APOL-12345678" --model local --save
```

**A hard guarantee.** Mark a model connection **require_redaction** and the runtime
refuses to send to it unless the agent runs a redaction hook - so a forgotten agent
config can never leak raw PII to that provider. Redaction runs off-process, so an
LLM-backed hook never blocks the session; the reversible map lives only in memory and
is cleared on reset / `end_session` / TTL eviction.

---

[Back to the docs index](../README.md#documentation)
