---
title: Traces
description: Every agent run leaves a record you can replay later to see exactly what it did.
---

Every agent run leaves a **trace**: a lasting record of what the agent actually
did, one you can replay step by step, no matter where the run started (the CLI,
the HTTP API, a WebSocket, a Telegram or WhatsApp message, or a scheduled job).
A trace answers "why did the agent do that?" long after the run is over.

## What a trace holds

- The prompt that triggered the run, and how it ended (`ok`, or an error with its reason).
- How long it took, and the model token usage.
- The ordered stream of steps: each tool call **with its arguments**, each tool result, any permission denials, and every model failover.
- The final reply.

Nested sub-agent runs (an agent calling another through `send_to_agent`) fold
into the same trace, so one record shows the whole tree of work.

## In the dashboard

Open **Traces** in the sidebar. The list shows the most recent runs for the
current workspace scope with their outcome, duration, and the tools each one
used. Click **Replay** on any run to walk it step by step: the prompt at the top,
then a timeline of every tool call, result, failover, token count, and the final
answer.

## From the CLI

```bash
pepe traces                       # recent runs across all projects
pepe traces --project acme        # only one project's runs
pepe traces --limit 10            # cap the list
pepe traces 1720000000123456      # replay one run by id, step by step
```

## Where traces live

Traces are stored in the same small built-in SQLite file as commitments and watches,
grouped by project (the default project uses `default`). Each project keeps only a
limited number of traces: as new ones arrive, the oldest are deleted, so the file
never grows without limit. Very long tool arguments and results are shortened before
being stored.

## Sending traces to an observability tool

Sending to [Langfuse](../langfuse/) needs nothing beyond the credentials most
installs already have set for it (`LANGFUSE_PUBLIC_KEY`/`LANGFUSE_SECRET_KEY`):
every finished run is sent as an OTLP trace the moment those are present,
off otherwise, and a delivery failure never touches the run it's describing.

For any other OTLP-speaking backend, set `OTEL_EXPORTER_OTLP_ENDPOINT`
instead and it takes over completely:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://your-collector.example.com
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 of user:pass>"
```

`OTEL_EXPORTER_OTLP_HEADERS` is a comma-separated `key=value` list, sent as
literal request headers. Both generic OpenTelemetry attributes (`gen_ai.*`)
and Langfuse's own (`langfuse.*`) are set on every span, so a Langfuse
endpoint renders fully and any other OTLP backend still gets a complete
trace either way. Two more standard OTEL variables, if you need them:
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` points the traces signal somewhere other
than `<endpoint>/v1/traces`, and `OTEL_SERVICE_NAME` renames the exported
service (default `pepe`). Full walkthrough: [Langfuse](../langfuse/).

Beyond the run's prompt/reply and per-tool-call input/output, each exported
trace also carries: the channel it came from (Telegram, the API, ...) as
trace metadata; the session key as both `session.id` and `user.id` (the
closest thing to a per-user identity Pepe has: exact for a one-on-one
channel, shared across everyone in a group chat); the running Pepe version
(`langfuse.release`); a level (`DEFAULT`/`WARNING`/`ERROR`) derived from how
the run actually finished; and, on each model-call span, the cost of that
call in your configured currency, computed the same way the usage ledger
computes it, and left off entirely rather than sent as a misleading zero
when the model has no known price.

<div class="note"><strong>Diagnostic, not a billing record.</strong> Traces exist to explain a run, and old or oversized ones get trimmed away. For token counts and cost you can invoice on, use the separate <a href="../billing/">usage ledger</a>, which never drops an entry.</div>
