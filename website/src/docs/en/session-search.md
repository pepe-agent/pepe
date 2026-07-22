---
title: Session search
description: An agent can find and read past conversations, built on the same durable traces you can already inspect.
---

An agent's own memory of a conversation lives only in that conversation's live process - once a session ends or the app restarts, that memory is gone. What survives is the [trace](../traces/) of every turn: a durable, SQLite-backed record kept regardless of whether the session that made it is still running.

The `session_search` tool gives an agent a way to search and read that history directly, without you having to paste old context back in. It is always-safe (no permission prompt, the same posture as `read_file`), and it is scoped to the calling agent's own project - one project's conversations are not another's to search.

**Within that project, how far one call can actually see depends on the agent's `session_search_scope`.** By default (`"self"`), every action only ever reaches the calling conversation's own history - the safe setting for an agent that talks to several different end customers, where one customer asking to "search my past conversations" must never be able to read another's. Widen it to `"project"` (a checkbox on the agent's edit page, or `manage_agent`'s `session_search_project_wide` flag) only for an agent with one operator/team on the other end - an internal tool with nobody else's conversation in the same project to leak.

## What it can do

- **`list_sessions`** - which conversations have happened in this project, most recently active first, each with its turn count.
- **`search`** - find conversations whose prompt or tool activity mentions a given word or phrase.
- **`session_history`** - every turn recorded for one session key, in order - a conversation's own timeline.
- **`show`** - one turn's complete transcript: every tool call, result, and the final reply.

```
You: Didn't we already sort out that invoice issue with Acme a few weeks back?

Agent: [session_search search: "Acme invoice"]
Yes - on July 3rd I found their May invoice had the wrong tax rate applied and
corrected it. Want me to check whether the same thing happened again this month?
```

This is search, not memory: an agent still only acts on what it reads back into the current conversation. Nothing found this way is silently assumed - it comes back as text the agent reads and can quote, same as any other tool result.
