---
title: Langfuse
description: Send agent runs to Langfuse for observability, and manage an agent's persona from a Langfuse prompt instead of config.json.
---

## Langfuse

[Langfuse](https://langfuse.com) is an optional connection, not a requirement:
nothing about Pepe assumes it's there. Two features use it:

- **Trace export**: every finished run is sent to Langfuse as an OTLP trace, so
  you can browse, debug and evaluate runs there.
- **Managed prompts**: an agent's persona is fetched from a prompt you edit in
  Langfuse, instead of `system_prompt`/`SOUL.md`. Opt-in per agent on top of
  the credentials below, via `langfuse_prompt`.

### Credentials

Both features read the same environment variables every official Langfuse SDK
uses, so credentials already set up for other tooling just work here too:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
# Only if you're not on cloud.langfuse.com:
export LANGFUSE_BASE_URL=https://your-self-hosted-langfuse.example.com
```

Get the key pair from your project's settings in Langfuse. Setting it turns
trace export on right away, for every agent (see below if you want prompts
managed from Langfuse too, or traces sent somewhere else entirely instead). A
Langfuse outage or a wrong key makes trace export fall back to silently
dropping the trace and a `langfuse_prompt` fetch fall back to the agent's
local persona; neither ever blocks a conversation or a run.

Both features read these variables from the running Pepe process itself, not
through an agent's own `bash` tool, which matters if you ever ask an agent to
help debug the connection. `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY` are
secret-shaped by name, so Pepe scrubs them out of the agent's own shell by
default, the same as any other credential (see [Secrets](../secrets/)). The
agent can still add the two names to `secrets.expose_env` itself if it needs
to check them directly; just be aware a 0-length read there means "scrubbed
from my shell," not "unset on the server."

### Trace export

The `LANGFUSE_*` pair above is enough on its own: trace export turns on the
moment `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` are both set, with no
separate OTEL variables required. Every finished run becomes one OTLP trace:
a root span for the whole run, a child span per tool call and per model call,
with both generic OpenTelemetry attributes and Langfuse's own set on each, so
sessions group correctly and generations are distinguished from plain tool
spans.

To send traces somewhere other than Langfuse (a self-hosted collector,
Honeycomb, any other OTLP-speaking backend), set the standard OTLP variables
instead, and they take over completely (the `LANGFUSE_*` pair is then only
used for managed prompts, if you're using those too):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://your-collector.example.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 of user:pass>"
```

Full detail, including the two extra OTEL variables you rarely need:
[Traces](../traces/#sending-traces-to-an-observability-tool).

### Managed prompts

```bash
pepe agent add support --langfuse-prompt support-persona
```

Set an agent's `langfuse_prompt` (CLI flag above, or the same field in the
dashboard's agent editor) to a prompt name in Langfuse, and that agent's
persona is fetched from there. Edit the prompt in Langfuse and the change
reaches Pepe within a few minutes, no redeploy. Opt-in per agent; an agent
with no `langfuse_prompt` set is completely unaffected, and one whose fetch
fails (unreachable, name doesn't resolve) just uses its local persona exactly
as if this were never configured. Reads the `LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`
pair above. Full detail: [Agents](../agents/#managing-a-persona-from-langfuse).
