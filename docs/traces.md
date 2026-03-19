# Traces

Every agent run leaves a **trace**: a durable, replayable record of what the agent
actually did, no matter which surface triggered it (the CLI, the HTTP API, a WebSocket,
a Telegram or WhatsApp message, or a scheduled job). A trace answers "why did the agent
do that?" long after the run is over.

A trace holds:

- the prompt that triggered the run and how it ended (`ok` or an error, with the reason);
- how long it took and the model token usage;
- the ordered stream of steps: each tool call **with its arguments**, each tool result,
  any permission denials, and every model failover;
- the final reply.

Nested sub-agent runs (an agent calling another through `send_to_agent`) fold into the
same trace, so one record shows the whole tree of work.

## In the dashboard

Open **Traces** in the sidebar. The list shows the most recent runs for the current
workspace scope with their outcome, duration and the tools each used. Click **Replay**
on any run to walk it step by step: the prompt at the top, then a timeline of every tool
call, result, failover, token count and the final answer.

## From the CLI

```bash
mix pepe traces                       # recent runs across all scopes
mix pepe traces --company acme        # only one company's runs
mix pepe traces --limit 10            # cap the list
mix pepe traces 1720000000123456      # replay one run by id, step by step
```

## Where it lives

Traces are written as one JSON file per run under
`<PEPE_HOME>/data/traces/<scope>/<id>.json` (the root scope lives under `root/`). The
directory is capped per scope; the oldest traces are trimmed so it stays bounded. Long
tool arguments and results are clipped in the stored record.

Traces are **diagnostic**, not a billing record. Token accounting for invoices lives in
the separate, append-only [usage ledger](billing.md).

---

[Back to the docs index](../README.md#documentation)
