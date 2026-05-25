---
title: Delegation (fan-out)
description: The delegate tool splits a wide job into throwaway parallel workers, each with its own fresh context window, so the whole thing takes as long as the slowest part instead of the sum.
---

"Compare these eight competitors" is not one task, it is eight, and doing it in one conversation costs you twice. It takes eight times as long. And every page fetched for competitor one is still sitting in the context window while the model reads about competitor eight, so the window fills with material nobody will look at again, and the final answer gets worse as it does.

The `delegate` tool hands the parts to throwaway workers, all at once:

```
you › compare the pricing pages of stripe, adyen and mollie

agent › delegate(tasks: [
          "Read stripe.com/pricing and report the card fee and any monthly minimum.",
          "Read adyen.com/pricing and report the card fee and any monthly minimum.",
          "Read mollie.com/pricing and report the card fee and any monthly minimum."
        ])
```

Each worker is a fresh run with its own context window and its own trace. It reads what it needs, answers the question it was given, and disappears. The parent gets three answers and never sees the three transcripts, so the work fits in a window it could not have fitted in before. And because the workers wait on the network at the same time, the whole thing takes as long as the slowest one, not the sum.

## Giving an agent the tool

You grant `delegate` the usual way, in the tool list:

```bash
pepe agent add lead --model openrouter --tools fetch_url,read_file,delegate
```

## A worker may read; it may not act

A worker inherits only the tools that need no permission: `read_file`, `list_dir`, `fetch_url`, `web_search`, and their kind. Anything that writes, runs, installs or deletes is taken away before the worker starts, and a worker cannot delegate further.

This is not a limitation waiting to be lifted. Three workers running at once are three workers that would want to ask you three questions at once, and *may I run this?* is not a question to be asked in triplicate. More to the point: fan-out is for **finding out**, and finding out is safe to do in parallel. **Acting** is not, and it stays where it belongs, in the one conversation you are actually watching. A worker that discovers something needs doing says so, and the parent does it, at the permission gate, in front of you.

The other guard is arithmetic. Without "a worker cannot delegate", one task becomes eight, becomes sixty-four, and the bill arrives before the answer.

<div class="note"><strong>A hard cap of eight tasks per call.</strong> The model is told about the cap, so it splits the work instead of being surprised by it.</div>

## Delegating as another agent

```
delegate(tasks: [...], agent: "researcher")
```

This runs the workers as a different agent, with that agent's persona and tools, still stripped of anything that acts. It obeys the same directed allowlist as `send_to_agent`: an agent may borrow the identity of another only if it was already allowed to message it. One authority for the act, not a second and weaker one. Routes are covered on the [Agents](../agents/) page.

## What it costs

Every worker is a real model call, metered and billed like any other, against the same project. Eight workers is eight turns. That is the trade: you are buying back wall-clock time and context-window room, and you are paying for it in tokens. For a task that would not have fitted in one window at all, it is not really a trade.

Each worker gets its own trace, so **Traces** in the [dashboard](../dashboard/) shows what each one actually did, not just what the parent said about it.
