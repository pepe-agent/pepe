# Evals

An **eval** replays a known prompt through an agent and asserts on the reply and on the
tools the agent used. It is your regression net for behavior: change a prompt, a model,
or a toolset, run the evals, and see immediately if anything you cared about broke. This
matters because agents are non-deterministic, so an exact-string test is useless: an eval
asserts the things that actually matter (did it call the right tool? did it mention the
answer? did it avoid claiming it has no access?).

## Running

```bash
mix pepe eval               # run every suite (bundled + your own)
mix pepe eval arithmetic    # run one suite
mix pepe eval list          # list suites and their case counts
mix pepe eval --seed        # copy the bundled suites into ~/.pepe/evals to edit
mix pepe eval help
```

Each case runs a real turn against a real model, so evals need a model configured. A run
prints a tick or cross per case (with the reason on failure) and a total; a non-passing
run exits non-zero, so it slots into CI.

## Suites shipped with Pepe

These run against your **default agent** (cases omit `agent`, so whatever `mix pepe agent
default` points at). The tool suites assume that agent has the matching built-in tools.

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

They are **templates**: they encode reasonable expectations, not universal truth. A weak
model or a differently-toolled agent will fail some, and that is the point. Run `mix pepe
eval --seed` to copy them into `~/.pepe/evals` and tune the prompts and assertions to your
own agents.

## Writing your own

A suite is a JSON file: a list of cases. Put yours in `~/.pepe/evals/<name>.json`; a file
there **shadows** a bundled suite of the same name.

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

Every `expect` key is optional; a case passes when all present assertions hold:

- `contains` / `not_contains`: the reply includes each string (case-insensitive) / none of them.
- `matches`: the reply matches this regex (use `(?i)` for case-insensitive).
- `tool_called` / `tool_not_called`: these tools did / did not run during the turn.

Omit `agent` to run against the default agent, or name one to pin the case to it.

---

[Back to the docs index](../README.md#documentation)
