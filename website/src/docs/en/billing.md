---
title: Billing & limits
description: Cap a company's monthly spend or message volume, mark up what you charge, and reset a cap early.
---

## Billing & limits

Every model call is metered per company (see Agents for what a company is and how to create one). On top of that metering, a company can optionally carry two independent monthly caps, plus a billing markup:

- **Spend cap** (`--budget`) - a hard ceiling in your configured currency. Once the month-to-date billable total reaches it, that company's agents stop making new model calls until the cap resets.
- **Message cap** (`--message-limit`) - a hard ceiling on customer-originated messages. Once reached, that company's agents stop replying to new inbound messages until it resets.
- **Markup** (`--markup`) - a multiplier applied to provider cost to get what you bill the client (e.g. `1.3` = provider cost +30%). Unset means you bill exactly the provider cost.

All three are optional and independent: set any of them, all of them, or none. Root (the default, non-company scope) can carry the same caps, set with `pepe company set root ...`. Root isn't a real company (it never shows in `company list`, can't be renamed or removed), but it isn't excluded from billing limits either.

### What counts toward the message cap

The message cap counts **one customer-originated message, once**, not every model call it takes to answer it. If an agent calls three tools before replying, that is still one message against the cap, the same way it is one message in the chat. Tool-calling iterations, cron runs, sub-agent-to-sub-agent messages, and heartbeats never count.

It only counts messages from customer-facing surfaces: Telegram, WhatsApp and other webhook channels, the embeddable widget. It deliberately excludes the `pepe chat` console, the dashboard's own test chat, and the HTTP API, since those are the operator using their own runtime, not a customer messaging it.

An individual agent can be exempted from the message cap entirely, which is useful for something like an always-on escalation agent that must never go quiet because the rest of the company hit its cap:

```bash
pepe agent add escalation --exempt-message-limit
```

There's currently no CLI way to flip that flag on an agent that already exists without touching its other settings, since `agent add` replaces the whole agent definition rather than patching one field. Toggle it from the agent's edit page on the dashboard instead.

### Setting the caps

```bash
pepe company set acme --budget 100
pepe company set acme --message-limit 5000
pepe company set acme --budget 100 --message-limit 5000 --markup 1.3
```

`company set` only touches the flags you pass; the rest of the company's settings are left alone. Pass `none` to clear a cap:

```bash
pepe company set acme --budget none
```

The same fields are editable from the Companies page on the dashboard.

### Resetting a cap early

A cap resets naturally at the start of each billing month, but you don't have to wait:

```bash
pepe company reset-budget acme
pepe company reset-messages acme
```

The Companies dashboard page has the same two buttons next to each cap's badge, with a confirmation showing the current count before it resets.

A reset does not delete anything; it just marks a cutoff. Spend or messages recorded before the reset stay in the ledger; they simply stop counting toward the cap going forward. This matters for one thing specifically: **the spend cap badge and the reset button only affect the operational count used to gate new model calls.** The actual month's billing record, what you'd invoice a client for, lives in Usage and always reflects the real total, reset or not. If you reset a company's spend cap mid-month, the Companies page badge will show a smaller number than the Usage page for that same month; that's expected, not a discrepancy, since they answer different questions ("has this company been throttled since I last reset it?" versus "what did this company actually cost this month?").
