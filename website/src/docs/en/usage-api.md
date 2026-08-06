---
title: Usage API
description: Read what has been spent over HTTP with a scoped token, per message, per model call, with or without your markup.
---

`/v1/usage` is what you build a billing integration on: it reads what has been spent, over HTTP, with a token that can see the figures but run nothing. It answers the question billing actually asks, which is not "what did this month cost" but "what did *that message* cost, and why".

Four endpoints, four zoom levels on the same ledger:

| Endpoint | One row per |
| --- | --- |
| `GET /v1/usage` | time bucket (hour, day, week, month, year) |
| `GET /v1/usage/events` | model call |
| `GET /v1/usage/runs` | inbound message |
| `GET /v1/usage/runs/:id` | that one message, call by call |

They use the same `Authorization: Bearer pepe_...` header as the rest of the [HTTP API](../api/), and they answer only for the projects the token reaches. See [Billing & limits](../billing/) for how the numbers themselves are calculated.

## A token that only reads

A token may run agents and may **not** read usage unless you say so, so nothing you have already minted changes. Mint a read-only billing token like this:

```bash
pepe token add --project acme --no-chat --usage --prices billable --label "acme billing"
```

That token can call `/v1/usage`, cannot call `/v1/chat/completions`, sees only the `acme` project, and sees only what the client pays. Hand it to a client's finance system without giving them a credential that can also spend your model budget.

The four permissions:

| Flag | Default | What it grants |
| --- | --- | --- |
| `--chat` / `--no-chat` | on | run agents (`/v1/chat/completions`, the WebSocket) |
| `--usage` | off | read `/v1/usage` |
| `--prices` | `billable` | how much of the money a read shows |
| `--content` | off | a run's detail may include the prompt and tool arguments/output |

Change them later without rotating the secret, so a client's integration keeps working while what it may see changes:

```bash
pepe token permissions abc123 --prices list
pepe token permissions abc123 --no-usage
```

The same fields are on the token cards in the dashboard, under **Tokens**, and an owner-style agent with the `manage_token` tool can mint one from a conversation. A **widget** token can never read usage: it sits in public page source.

## How much money it sees

Every metered call has three numbers, and `--prices` picks which of them a read returns:

* **`billable`**: list price × the project's markup. What the client pays. The default, and the only one a client's token should ever have.
* **`list`**: the same tokens at the model's price, with no markup applied.
* **`all`**: both, plus `cost` (what you actually paid) and `margin`. Your own view.

`billable` and `list` are exclusive rather than cumulative. Showing both would reveal their ratio, and that ratio is your markup, your margin. A token given `list` is being shown list prices *instead*, not as well.

This is decided by the token, never by the request. A client that calls `?prices=all` gets its own token's view back, not the one it asked for.

## Aggregates

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.example.com/v1/usage?granularity=day&limit=30"
```

```json
{
  "object": "usage.summary",
  "granularity": "day",
  "currency": "BRL",
  "scope": { "projects": ["acme"], "agent": null },
  "period": { "from": 1777536000, "to": null },
  "totals": { "calls": 412, "input_tokens": 918204, "output_tokens": 61233, "total_tokens": 979437, "billable": 13.55 },
  "buckets": [{ "key": "2026-07-28", "calls": 61, "input_tokens": 140233, "output_tokens": 9120, "total_tokens": 149353, "billable": 2.06 }],
  "by_model": [],
  "by_agent": [],
  "by_project": []
}
```

`granularity` is one of `hour`, `day`, `week`, `month`, `year`, and `limit` caps how many buckets come back (60 by default).

An aggregate has to read every entry in its window in order to sum it, so with no `from` this endpoint defaults to the **last 90 days** rather than the whole history. The window it used comes back as `period`, so a report never quietly covers less than you think. Ask for more whenever you need it: `from=0` is all of it. An `all` token additionally gets `subscriptions` and `margin` at the top level, and a `markup` on each entry of `by_project`.

## One row per model call

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.example.com/v1/usage/events?session=telegram:12345&limit=100"
```

```json
{
  "object": "list",
  "data": [
    {
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/sales",
      "model": "gpt-4o",
      "run_id": "1785312000123456",
      "session": "telegram:12345",
      "source": "telegram",
      "input_tokens": 4120,
      "output_tokens": 210,
      "cached_input_tokens": 3072,
      "total_tokens": 4330,
      "subscription": false,
      "billable": 0.0231
    }
  ],
  "has_more": true,
  "next_cursor": 84213
}
```

Pass `next_cursor` back as `cursor` for the next page. Paging runs on an opaque row id rather than on the timestamp, because `at` has one-second granularity and a page boundary landing inside a busy second would either lose rows or repeat them.

## One row per message

This is the endpoint most integrations want. A single inbound message often costs several model calls: the agent answers, calls a tool, is fed the result, calls another, and answers again. `/v1/usage/runs` groups those calls back into the message that caused them.

```bash
curl -H "Authorization: Bearer $TOKEN" "https://pepe.example.com/v1/usage/runs?limit=50"
```

```json
{
  "object": "list",
  "data": [
    {
      "id": "1785312000123456",
      "at": 1785312000,
      "project": "acme",
      "agent": "acme/sales",
      "session": "telegram:12345",
      "source": "telegram",
      "ms": 8412,
      "outcome": "ok",
      "tools": ["web_search", "fetch_url", "write_file"],
      "tool_calls": 3,
      "calls": 4,
      "input_tokens": 18320,
      "output_tokens": 940,
      "total_tokens": 19260,
      "billable": 0.0912
    }
  ],
  "has_more": false,
  "next_cursor": null
}
```

`source` is what triggered the run (`telegram`, `api`, `cron`, `flow`, and so on), `outcome` is `ok` or `error`, and `ms` is how long the whole message took.

Note what `calls: 4` and `tool_calls: 3` say together. A tool costs no tokens of its own; what makes a message expensive is the number of model calls, because each iteration re-sends a context that the previous tool result just made bigger. That is why the run, not the tool, is the unit worth reading.

## One message, call by call

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://pepe.example.com/v1/usage/runs/1785312000123456"
```

Returns the same fields as the list row, plus `breakdown`: every model call in that run, in order, with its own tokens, cache hits and money. That is the answer to "why did this message cost that much".

A token minted with `--content` also gets a `content` object carrying the prompt and each tool's arguments and output. Without it there is no `content` key at all. Off by default on purpose: a usage report is a bill, and a bill is not a transcript. Content also comes from the run's [trace](../traces/), which is trimmed per project, so an old enough run reports `content: null` rather than pretending it never had any.

## Filters

Every endpoint takes the ones that make sense for it:

| Parameter | Where | Meaning |
| --- | --- | --- |
| `project` | all | one project, and only one the token already reaches |
| `agent` | all | one agent's spend |
| `model` | summary, events | one model connection |
| `source` | all | `telegram`, `api`, `cron`, `flow`, … |
| `session` | all | one conversation |
| `run_id` | summary, events | one message's calls |
| `from` / `to` | all | unix seconds, `[from, to)` |
| `limit` | all | page size (max 1000) |
| `cursor` | events, runs | the previous page's `next_cursor` |
| `granularity` | summary | `hour`, `day`, `week`, `month`, `year` |

A filter can only narrow what the token already reaches. Naming a project outside its scope is a **403**, not an empty result, and an agent-locked token stays on its own agent whatever `agent=` says. `model=` and `run_id=` on `/runs` are a **400**: a run has no single model, one run id is what `/runs/:id` is for, and a filter that silently does nothing returns a report you would believe is narrower than it is.

## Errors

| Status | When |
| --- | --- |
| 401 | missing or unknown token |
| 403 | the token may not read usage, or asked for a project it cannot reach |
| 404 | no such run within the token's scope |
| 400 | an unusable parameter |

A run belonging to another project answers **404** rather than 403, so the endpoint never confirms that an id exists somewhere you cannot see.
