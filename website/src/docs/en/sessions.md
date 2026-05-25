---
title: Sessions
description: Use server-side conversation memory over HTTP and WebSocket.
---

## Sessions: stateful vs stateless

By default the API is **stateless**: each request must carry the full message history, exactly like OpenAI. You send everything, Pepe answers, nothing is remembered.

Pepe also offers a **stateful** mode that most OpenAI servers do not. Attach a session id and the server keeps the conversation for you. On every later call you send only the newest user message; Pepe appends it to the stored history, runs the agent, and remembers the result. This is convenient for chat UIs and messaging bots where you do not want to ship the whole transcript each time.

## CLI vs API

`pepe run` is always one-shot: it does not accept `session_id` and does not
remember the previous command. To keep context in the terminal, use the console:

```bash
pepe chat assistant --session my-session
```

The HTTP API takes the session key from **two fields, and they compose**.

- **`user`** identifies *who* is talking. It is the OpenAI-standard field, so any stock OpenAI SDK gets server-side memory without leaving the standard shape. This is the one to reach for.
- **`session_id`**, in the JSON body or an `x-session-id` header, identifies *which conversation* of theirs. Use it when one person can have several separate threads.

How they combine:

| Sent | Session key |
| --- | --- |
| `user` only | `user` |
| `session_id` only | `session_id` |
| both | `user:session_id` (independent threads per person) |
| both, same value | deduped to one |
| neither (or blank) | stateless |

So on WhatsApp you can pass `user` = the phone number and `session_id` = a thread id, and every thread of every contact is its own conversation, isolated from the rest.

```bash
# Turn 1: only the new message is needed; the server keeps the history.
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "My name is Ada."}]
  }'

# Turn 2: same session id, just the follow-up. The agent remembers "Ada".
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "assistant",
    "user": "user-42",
    "messages": [{"role": "user", "content": "What is my name?"}]
  }'
```

In stateful mode the response includes the `session_id` you used, so you can echo it back on the next call. Stateful sessions work with streaming too; just add `"stream": true`.

### Recovering from a restart

If Pepe goes down mid-turn (a deploy, a crash) while session persistence is on, the interrupted conversation is not just lost. On the next boot, Pepe notices any session whose last turn never finished, replays it as an internal follow-up, and delivers the reply to wherever the conversation was happening (Telegram, the dashboard, whichever channel it came from), so an interrupted message still gets answered instead of silently vanishing. This only applies to persisted sessions (`serve`/`gateway`), not one-shot `pepe run` calls.

<div class="note"><strong>Tenancy isolation.</strong> Session keys are namespaced by project internally. The same session id used under two different tokens (two different projects) never reaches the same conversation, so one tenant can never read another tenant's session.</div>

To go stateless, simply omit all three id sources and send the full `messages` array yourself. That is the plain OpenAI behavior.
