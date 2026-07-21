---
title: Billing & limits
description: Meter every model call per project, price it, mark up what you charge, cap a project's monthly spend or message volume, and export a client invoice.
---

## What a call costs

Every model call is metered and attributed to the agent's project, so you can bill a client per token. Metering happens at the single point every surface flows through (the console, the HTTP `/v1` API, the WebSocket, Telegram, and every webhook channel), and it appends to a durable, append-only ledger in the same small embedded SQLite file as commitments, watches and traces, keyed by project (e.g. `default`). That's the audit trail for what gets charged. Upgrading from an older Pepe that wrote it as one JSONL file per project per month under `~/.pepe/data/usage/<slug>/YYYY-MM.jsonl`? Run `mix pepe config migrate-data` once to bring the old entries over - the source files are left in place, not deleted, so you can remove that directory by hand once you've confirmed the import.

**Cost** is `tokens × the model's price`, quoted per 1M tokens. A price is resolved in layers, and the first layer that answers wins:

1. The **manual price** set on the model connection.
2. A **live cache** at `~/.pepe/data/price_book.json`, refreshed from OpenRouter and the LiteLLM price map.
3. A **built-in seed** of well-known prices, which is the offline fallback.

So a known model is priced automatically, and you only type a price in to override one or to fill a gap. Set per-model prices under Models, then Edit, on the dashboard, or refresh the live cache yourself:

```bash
pepe usage prices --refresh
```

Prices also refresh once a week on their own while `serve` or a gateway is running.

**The amount to bill** is `list price × the project's markup`, the optional per-project multiplier described below. What you paid and what you bill are always shown side by side, so a markup never hides the real cost from your own team.

## Subscriptions (ChatGPT Plus, Claude Max)

A conversation that runs on a subscription login costs nothing per token: the month was paid for in advance, whether you send one message or ten thousand. It is still worth exactly the same to the client as one that ran on the paid API, so Pepe keeps three numbers rather than two.

| Number | What it means |
|---|---|
| **List** | `tokens × the model's price`. What these tokens would have cost on the API, whether or not they did. |
| **To bill** | `list × markup`. What the client pays, computed from the list price and **not** from what you spent. |
| **Cost** | What you actually paid. Zero for tokens a subscription served, plus that subscription's flat monthly fee, counted once. |

Billing from the list price is the whole point. The subscription will lapse one day and the same work will fall through to the paid API, and on that day the client's invoice must not move. A price that tracks your supply arrangements is a price you have to explain.

Tell Pepe what a subscription costs you and the margin comes out right:

```json
{
  "models": {
    "claude-max": {
      "oauth": { "provider": "anthropic" },
      "monthly_cost": 100
    }
  }
}
```

The `oauth` block is written for you by `pepe model login`. `monthly_cost` is what that subscription costs you per month. Leave `monthly_cost` unset and the fee simply never appears against the margin, which makes the reported margin an optimistic upper bound rather than a wrong number. `pepe doctor` says so.

Whether a call ran on a subscription is decided **when it is recorded**, not when the ledger is read. Switch a connection from a login to an API key and last month's entries keep meaning what they meant.

## Billing & limits

Every model call is metered per project (see Agents for what a project is and how to create one). On top of that metering, a project can optionally carry two independent monthly caps, plus a billing markup:

- **Spend cap** (`--budget`) - a hard ceiling in your configured currency. Once the month-to-date billable total reaches it, that project's agents stop making new model calls until the cap resets.
- **Message cap** (`--message-limit`) - a hard ceiling on customer-originated messages. Once reached, that project's agents stop replying to new inbound messages until it resets.
- **Markup** (`--markup`) - a multiplier applied to provider cost to get what you bill the client (e.g. `1.3` = provider cost +30%). Unset means you bill exactly the provider cost.

All three are optional and independent: set any of them, all of them, or none. The default project carries the same caps like any other, set with `pepe project set default ...` (or whatever you have renamed it to).

### What counts toward the message cap

The message cap counts **one customer-originated message, once**, not every model call it takes to answer it. If an agent calls three tools before replying, that is still one message against the cap, the same way it is one message in the chat. Tool-calling iterations, cron runs, sub-agent-to-sub-agent messages, and heartbeats never count.

It only counts messages from customer-facing surfaces: Telegram, WhatsApp and other webhook channels, the embeddable widget. It deliberately excludes the `pepe chat` console, the dashboard's own test chat, and the HTTP API, since those are the operator using their own runtime, not a customer messaging it.

An individual agent can be exempted from the message cap entirely, which is useful for something like an always-on escalation agent that must never go quiet because the rest of the project hit its cap:

```bash
pepe agent add escalation --exempt-message-limit
```

There's currently no CLI way to flip that flag on an agent that already exists without touching its other settings, since `agent add` replaces the whole agent definition rather than patching one field. Toggle it from the agent's edit page on the dashboard instead.

### Setting the caps

```bash
pepe project set acme --budget 100
pepe project set acme --message-limit 5000
pepe project set acme --budget 100 --message-limit 5000 --markup 1.3
```

`project set` only touches the flags you pass; the rest of the project's settings are left alone. Pass `none` to clear a cap:

```bash
pepe project set acme --budget none
```

The same fields are editable from the Projects page on the dashboard.

### Resetting a cap early

A cap resets naturally at the start of each billing month, but you don't have to wait:

```bash
pepe project reset-budget acme
pepe project reset-messages acme
```

The Projects dashboard page has the same two buttons next to each cap's badge, with a confirmation showing the current count before it resets.

A reset does not delete anything; it just marks a cutoff. Spend or messages recorded before the reset stay in the ledger; they simply stop counting toward the cap going forward. This matters for one thing specifically: **the spend cap badge and the reset button only affect the operational count used to gate new model calls.** The actual month's billing record, what you'd invoice a client for, lives in Usage and always reflects the real total, reset or not. If you reset a project's spend cap mid-month, the Projects page badge will show a smaller number than the Usage page for that same month; that's expected, not a discrepancy, since they answer different questions ("has this project been throttled since I last reset it?" versus "what did this project actually cost this month?").

## Reading usage and exporting invoices

```bash
pepe usage                                   # every project, by month, per project
pepe usage --project acme --granularity day  # one project, by day
pepe usage export --project acme             # a client invoice (Markdown, or --format csv)
pepe usage prices --refresh                  # refresh the live price cache
pepe usage help                              # the full walkthrough
```

`usage export` turns a project's month into a client invoice, in Markdown or CSV. An agent can do the same thing itself with the `export_invoice` tool, so a monthly scheduled task can export each client's invoice and send it, using Pepe to bill for its own use.

On the dashboard, the Usage & billing section shows tokens, cost, and amount to bill by cycle (hour, day, week, month, year), with breakdowns by project, model, and agent. Per-model prices are set under Models, then Edit; a project's markup under Projects, then Edit.

Currency is a label only. It defaults to `USD` and you change it by setting `"currency"` in `config.json`. There is no FX conversion, so the number is in whatever currency your provider quotes its prices.
