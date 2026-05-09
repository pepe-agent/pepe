# Usage metering & billing

Every model call is metered and attributed to the agent's company, so you can bill a
client per token. Metering happens at the one point all surfaces flow through (CLI,
HTTP `/v1`, WebSocket, Telegram) and appends to a durable, append-only ledger under
`~/.pepe/data/usage/<company>/YYYY-MM.jsonl`, the audit trail for what's charged.

**Cost** = `tokens × the model's price` (per 1M tokens). A price is resolved in
layers: the **manual price** on the model wins, then a **live cache**
(`~/.pepe/data/price_book.json`, refreshed from OpenRouter + the LiteLLM price
map), then a **built-in seed** of well-known prices (offline fallback). So known
models are priced automatically; you only type a price to override or fill a gap.

**Amount to bill** = `list price × the company's markup`, an optional per-company
multiplier (`1.3` = +30%; blank = bill exactly the list price). Both what you paid and
what you bill are always shown side by side, so the markup never hides the real cost
from your team.

## Subscriptions (ChatGPT Plus, Claude Max)

A conversation that runs on a subscription login costs nothing per token: the month was
paid for in advance, whether you send one message or ten thousand. But it is worth
exactly the same to the client as one that ran on the paid API, so Pepe keeps three
numbers rather than two:

| | |
|---|---|
| **List** | `tokens × the model's price`. What these tokens would have cost on the API, whether or not they did. |
| **To bill** | `list × markup`. What the client pays, computed from the list price and **not** from what you spent. |
| **Cost** | What you actually paid. Zero for tokens a subscription served, plus that subscription's flat monthly fee, counted once. |

Billing from the list price is the whole point. The subscription will lapse one day and
the same work will fall through to the paid API, and on that day the client's invoice
must not move. A price that tracks your supply arrangements is a price you have to
explain.

Tell Pepe what a subscription costs you and the margin comes out right:

```jsonc
"claude-max": {
  "oauth": { "provider": "anthropic", "...": "..." },   // written by `pepe model login`
  "monthly_cost": 100                                   // what you pay for it, per month
}
```

Leave `monthly_cost` unset and the fee simply never appears against the margin, which
makes the reported margin an optimistic upper bound rather than a wrong number.
`pepe doctor` says so.

Whether a call ran on a subscription is decided **when it is recorded**, not when the
ledger is read: switch a connection from a login to an API key and last month's entries
keep meaning what they meant.

```bash
mix pepe usage                                  # all scopes, by month, per company
mix pepe usage --company acme --granularity day # a company, by day
mix pepe usage export --company acme            # a client invoice (Markdown or --format csv)
mix pepe usage prices --refresh                 # refresh the live price cache
```

**Invoices.** `usage export` turns a company's month into a client invoice (Markdown
or CSV), and the `export_invoice` **tool** lets an agent do it itself, so a monthly
scheduled task can export each client's invoice and send it, using Pepe to bill for
its own use.

Prices also auto-refresh once a week while `serve`/`gateway` is up. In the dashboard,
the **Usage & billing** section shows tokens, cost and amount-to-bill by cycle
(hour / day / week / month / year) with breakdowns by company, model and agent; set
per-model prices under **Models -> Edit** and a company's markup under
**Companies -> Edit**. Currency is a label only (default `USD`, set `"currency"` in
config); there's no FX conversion. Full walkthrough: `mix pepe usage help`.

---

[Back to the docs index](../README.md#documentation)
