---
title: Langfuse
description: Send agent runs to Langfuse for observability, and manage an agent's persona from a Langfuse prompt instead of config.json.
---

## Langfuse

[Langfuse](https://langfuse.com) is an optional connection, not a requirement -
nothing about Pepe assumes it's there. Two independent features use it, and
you can turn on either one, both, or neither:

- **Trace export**: every finished run is sent to Langfuse as an OTLP trace, so
  you can browse, debug and evaluate runs there.
- **Managed prompts**: an agent's persona is fetched from a prompt you edit in
  Langfuse, instead of `system_prompt`/`SOUL.md`.

### Credentials

Both features read the same environment variables every official Langfuse SDK
uses, so credentials already set up for other tooling just work here too:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Only if you're not on cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://your-self-hosted-langfuse.example.com
```

Get the key pair from your project's settings in Langfuse. Neither feature
does anything until its own credentials are set (see below - trace export
reads a different pair of variables, the standard OTEL ones); a Langfuse
outage or a wrong key only makes that one feature fall back silently, it
never blocks a conversation or a run.

### Trace export

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://cloud.langfuse.com/api/public/otel
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 of pk-lf-...:sk-lf-...>"
```

This is the standard OTLP/OTEL variables, not the `LANGFUSE_*` pair above -
Langfuse's OTLP endpoint authenticates with a literal `Authorization` header,
base64 of `public-key:secret-key`. Every finished run becomes one OTLP trace:
a root span for the whole run, a child span per tool call and per model call,
with both generic OpenTelemetry attributes and Langfuse's own set on each, so
sessions group correctly and generations are distinguished from plain tool
spans. Off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set; works with any other
OTLP-speaking backend too, not only Langfuse. Full detail, including the two
extra OTEL variables you rarely need: [Traces](../traces/#sending-traces-to-an-observability-tool).

### Managed prompts

```bash
pepe agent add support --langfuse-prompt support-persona
```

Set an agent's `langfuse_prompt` (CLI flag above, or the same field in the
dashboard's agent editor) to a prompt name in Langfuse, and that agent's
persona is fetched from there - edit the prompt in Langfuse and the change
reaches Pepe within a few minutes, no redeploy. Opt-in per agent; an agent
with no `langfuse_prompt` set is completely unaffected, and one whose fetch
fails (unreachable, name doesn't resolve) just uses its local persona exactly
as if this were never configured. Reads the `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
pair above. Full detail: [Agents](../agents/#managing-a-persona-from-langfuse).
