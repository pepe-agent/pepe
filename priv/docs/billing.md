# Usage metering & billing

Pepe meters every model call and turns tokens into money so you can bill a
client per project.

## What gets recorded

Each call the runtime makes to a model appends one line to a durable, append-only
ledger under `~/.pepe/data/usage/<slug>/YYYY-MM.jsonl`:

```json
{"at": 1720000000, "agent": "acme/sales", "model": "gpt-4o", "in": 812, "out": 143}
```

The project comes from the agent's handle (`acme/sales` -> project `acme`; a
bare-name agent -> the `default` project). Metering happens at the one point every
surface flows through (CLI, HTTP `/v1`, WebSocket, Telegram), so nothing is
missed and nothing is double-counted. The ledger never expires - it's the audit
trail for what a client is charged.

## From tokens to money

**Cost** = `input_tokens × input_price + output_tokens × output_price`, where the
price is per 1,000,000 tokens. A model's price is resolved in layers, most
specific first:

1. the **manual price** you set on the model connection (always wins);
2. the **live cache** at `~/.pepe/data/price_book.json`, refreshed from
   OpenRouter's public `/models` and the community LiteLLM price map;
3. a **built-in seed** of well-known model prices (offline fallback).

Because of the fallback, known models are priced automatically - you only need to
type a price for a model the book doesn't know, or to override it.

**Amount to bill** = `cost × the project's markup`. The markup is an optional
multiplier on the project (e.g. `1.3` = +30%); a project with no markup bills
exactly the provider cost. The dashboard always shows both the provider cost and
the amount to bill, side by side - the markup never hides the real cost from your
team.

## Refreshing prices

Prices change, so the cache refreshes:

- **on demand** - the "Refresh prices" button on the Usage page, or
  `mix pepe usage prices --refresh`;
- **automatically** - once it's older than a week, while a server surface
  (`mix pepe serve` / `gateway`) is running.

The seed keeps working with zero network; the cache just layers current prices on
top.

## Seeing the numbers

- **Dashboard** - the **Usage & billing** section: pick a cycle
  (hour / day / week / month / year), see tokens, provider cost and amount to
  bill per cycle, plus breakdowns by project, model and agent. Use the Workspace
  scope selector to focus one project.
- **CLI**:

  ```bash
  mix pepe usage                                  # all scopes, by month, per project
  mix pepe usage --project acme --granularity day
  mix pepe usage prices --refresh                 # update the live price cache
  ```

## Invoices

Turn a project's month into a client invoice - Markdown (a readable statement, good
as an email body) or CSV (for a spreadsheet). Line items are per model, with the
provider cost and the marked-up amount due.

```bash
mix pepe usage export --project acme                       # this month, Markdown, to stdout
mix pepe usage export --project acme --month 2026-06 --format csv --output acme-june.csv
```

An **agent** can do this itself with the `export_invoice` tool - it saves the invoice
under `~/.pepe/data/invoices/` and returns it inline. Combined with a scheduled
task, Pepe bills for itself: e.g. a monthly cron whose prompt is *"on the 1st,
export last month's invoice for each project and email it to the client."* (Sending
needs a channel or an email tool/MCP; the invoice tool produces the document.)

## Setting prices and markup

- **Per-model price** - Models section -> **Edit** a connection -> *Input price* /
  *Output price* (per 1M tokens). Leave blank to use the known/auto price.
- **Per-project markup** - Projects section -> **Edit** a project -> *Billing
  markup*. Blank = bill exactly the provider cost.
- **Currency** - a label only (default `USD`); prices are entered and shown in it
  with no FX conversion. Set `"currency"` in `~/.pepe/config.json`.
