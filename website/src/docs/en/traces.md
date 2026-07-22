---
title: Traces
description: A durable, replayable record of what every agent run actually did.
---

Every agent run leaves a **trace**: a durable, replayable record of what the
agent actually did, no matter which surface triggered it (the CLI, the HTTP API,
a WebSocket, a Telegram or WhatsApp message, or a scheduled job). A trace answers
"why did the agent do that?" long after the run is over.

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

Traces live in the same small embedded SQLite file as commitments and watches, keyed by
project (the default project uses `default`). Kept count is capped per project, so the
oldest traces are trimmed and the table stays bounded. Long tool arguments and results
are clipped in the stored record.

<div class="note"><strong>Diagnostic, not a billing record.</strong> Traces exist to explain a run, and they are trimmed and clipped to stay bounded. Token accounting for invoices lives in the separate, append-only <a href="../billing/">usage ledger</a>.</div>
