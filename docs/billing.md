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

**Amount to bill** = `cost × the company's markup`, an optional per-company
multiplier (`1.3` = +30%; blank = bill exactly the provider cost). Both the provider
cost and the amount to bill are always shown side by side, so the markup never hides
the real cost from your team.

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
