---
title: Session search
description: Your agent can look up past conversations on its own, using the same trace records you can already inspect.
---

An agent's working memory of a conversation only lasts while that conversation is running: once the session ends or the app restarts, it is gone. What survives is the [trace](../traces/) of every turn, a durable record kept in SQLite whether or not the session that made it is still alive.

The `session_search` tool lets an agent search and read that history on its own, so you never have to paste old context back in. It is always-safe (no permission prompt, the same posture as `read_file`), and it only sees the calling agent's own project: one project's conversations are never searchable from another.

**Within that project, how far one call can actually see depends on the agent's `session_search_scope`.** The default, `"self"`, means every action reaches only the calling conversation's own history. That is the safe setting for an agent that talks to several different end customers: one customer asking to "search my past conversations" must never be able to read another customer's. Widen it to `"project"` (a checkbox on the agent's edit page, or `manage_agent`'s `session_search_project_wide` flag) only for an agent with a single operator or team on the other end, an internal tool where there is nobody else's conversation in the same project to leak.

## What it can do

- **`list_sessions`**: which conversations have happened in this project, most recently active first, each with its turn count.
- **`search`**: find conversations whose prompt or tool activity mentions a given word or phrase.
- **`session_history`**: every turn recorded for one session key, in order. A conversation's own timeline.
- **`show`**: one turn's complete transcript, with every tool call, result, and the final reply.

```
You: Didn't we already sort out that invoice issue with Acme a few weeks back?

Agent: [session_search search: "Acme invoice"]
Yes - on July 3rd I found their May invoice had the wrong tax rate applied and
corrected it. Want me to check whether the same thing happened again this month?
```

This is search, not memory: an agent still only acts on what it reads back into the current conversation. Nothing found this way is silently assumed; it comes back as text the agent reads and can quote, the same as any other tool result.
