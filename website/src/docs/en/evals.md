---
title: Evals
description: Replay known prompts through an agent and assert on the reply and the tools it used.
---

An **eval** replays a known prompt through an agent and asserts on the reply and
on the tools the agent used. It is your regression net for behavior: change a
prompt, a model, or a toolset, run the evals, and see immediately whether
anything you cared about broke.

This matters because agents are non-deterministic, so an exact-string test is
useless. An eval asserts the things that actually matter. Did it call the right
tool? Did it mention the answer? Did it avoid claiming it has no access?

## Your traces are the test data you already have

The hard part of an eval suite is not running it, it is *writing* it, and nobody
ever finds the afternoon. So do not write one. When an agent handles something
well, keep that run:

```bash
pepe eval add a1b2c3                                   # a trace id
pepe eval add a1b2c3 --suite support --contains "refund,5 business days"
```

In the dashboard it is a button on the trace: **✓ This went right**.

### What the case actually asserts

The case keeps the prompt and the agent verbatim, and asserts **the tools the
agent used**. That is the assertion worth having. It survives model updates and
rewording, and it is exactly what changes when an edit goes wrong: the agent
stops looking things up and starts inventing them, or reaches for a shell where
it used to read a file. A model that answers the same question with the same
tools is a model that still works the way you decided it should.

It deliberately does **not** demand the same sentence back. Two runs of one
prompt never produce one, and a test that insists gets muted within a week, and
from then on protects nothing. The reply that was right is kept in the case under
`recorded`, for whoever reads a failure. If some words in it *were* the point,
say so with `--contains` and they get asserted too.

Failed runs are refused. Promoting one would freeze the failure as the
expectation, and hand you a green suite for it.

## How this actually goes, start to finish

You have never written an eval and you are not going to start today. Fine. Do
this instead.

**1. Use Pepe normally.** Talk to your agent, let clients talk to it. Every run
is already being recorded, so you do not have to do anything to make that happen.

**2. When something goes well, say so.** Open the dashboard, go to
[Traces](../traces/), click the run, press **✓ This went right**. That is the
whole ceremony. From the terminal it is the same thing:

```bash
pepe traces                       # the recent runs, with their ids
pepe eval add a1b2c3              # keep that one
# ✓ added to recorded: What is the price of the annual plan?
#   agent: support
#   asserts it still calls: read_file, web_search
#   run it with: pepe eval recorded
```

Do that four or five times over a week, whenever you notice the agent doing the
right thing. You now have a suite that describes your agent, written by your
agent, about the things your clients actually ask.

**3. Before you change anything, run it.**

```bash
pepe eval recorded
```

```
▸ recorded
  ✓ What is the price of the annual plan?
  ✓ Cancel my subscription
  ✗ Where is my order?
      tool read_file was not called
  2/3 passed
```

That cross is the whole point of the feature. The agent still answered. The
answer still read fine. It just stopped opening the file and started reciting
from memory, and next month, when the price changes, it would have gone on
confidently quoting the old one. No exception was raised, no log line was
written, and without this suite you would have found out from a client.

**4. Put it in CI.** A non-passing run exits non-zero, so it drops straight in
next to your tests. Now a persona edit that breaks something cannot reach
production quietly.

<div class="note"><strong>When a case is wrong, delete it.</strong> These are JSON files under <code>~/.pepe/evals/</code>. A case that no longer reflects what you want is a case to remove, not to argue with. The suite is a record of decisions, and decisions change.</div>

## Running

```bash
pepe eval               # run every suite (bundled + your own)
pepe eval arithmetic    # run one suite
pepe eval list          # list suites and their case counts
pepe eval add TRACE_ID  # keep a run that went right (see above)
pepe eval --seed        # copy the bundled suites into ~/.pepe/evals to edit
pepe eval help
```

Each case runs a real turn against a real model, so evals need a model
configured. A run prints a tick or a cross per case (with the reason on failure)
and a total. A non-passing run exits non-zero, so it slots into CI.

## Suites shipped with Pepe

These run against your **default agent**, since the cases omit `agent`, so
whatever `pepe agent default` points at. The tool suites assume that agent has
the matching built-in tools.

| Suite | Checks |
|---|---|
| `smoke` | Responds at all, echoes, answers a basic fact without a false "I can't". |
| `arithmetic` | Add, multiply, percentage, a word problem, a negative result. |
| `reasoning` | Syllogism, sequence, the 9.9-vs-9.11 decimal trap, letter counting. |
| `knowledge` | Static facts (capital, planet, moon landing) without fabricated uncertainty. |
| `formatting` | One-word answers, uppercase, a small JSON object, a list. |
| `language` | Replies in the language asked (pt / es / en) and translates. |
| `instruction-following` | Returns only what was asked, strict yes/no, count constraints. |
| `tools-shell` | Actually calls `bash` and reports the output. |
| `tools-web` | Calls `fetch_url` (reads example.com) and `web_search`. |
| `tools-files` | Calls `write_file` / `read_file` / `list_dir` (writes under `/tmp`). |
| `tool-judgment` | Answers known facts directly, reaches for a tool only when it must. |
| `prompt-injection` | Ignores instructions embedded in data (documents, reviews, emails). |
| `grounding` | Answers from the provided text and admits when the answer is not in it. |
| `safety` | Does not produce a harmful payload, does not fabricate a fake source. |

They are **templates**: they encode reasonable expectations, not universal truth.
A weak model or a differently-toolled agent will fail some, and that is the
point. Run `pepe eval --seed` to copy them into `~/.pepe/evals` and tune the
prompts and assertions to your own agents.

## Writing your own

A suite is a JSON file: a list of cases. Put yours in `~/.pepe/evals/<name>.json`.
A file there **shadows** a bundled suite of the same name.

```json
[
  {
    "name": "searches before answering a live question",
    "agent": "assistant",
    "prompt": "What is the USD to BRL rate right now?",
    "expect": {
      "contains": ["real"],
      "not_contains": ["i don't have access"],
      "matches": "\\d",
      "tool_called": ["web_search"],
      "tool_not_called": ["bash"]
    }
  }
]
```

Every `expect` key is optional, and a case passes when all the assertions present
hold:

| Key | Passes when |
|---|---|
| `contains` | The reply includes each string (case-insensitive). |
| `not_contains` | The reply includes none of these strings. |
| `matches` | The reply matches this regex (use `(?i)` for case-insensitive). |
| `tool_called` | These tools ran during the turn. |
| `tool_not_called` | These tools did not run during the turn. |

Omit `agent` to run the case against the default agent, or name one to pin the
case to it.
