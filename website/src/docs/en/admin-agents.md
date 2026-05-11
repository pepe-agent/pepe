---
title: Admin agents
description: Let one agent manage and train others with the manage_agent tool, scoped by a directed can_manage allowlist.
---

An agent can administer and **train other agents**. With the `manage_agent` tool it can
set another agent's persona, model, tools and memory, or create new agents from
scratch. Authority is a **directed, per-agent allowlist** called `can_manage`, so you
can run several admins at once, each scoped to a different set of agents.

## The can_manage scope

| `can_manage` | What it means |
|--------------|---------------|
| omitted, or `nil` | Itself only. This is the default. |
| `[]` | Nobody, not even itself. A locked client agent. |
| `[a, b]` | Exactly those agents. Add its own name to include itself. |
| `["*"]` | Every agent. An explicit super-admin. |

```bash
# boss can now administer "sales"
pepe agent manage boss sales

# a super-admin over all agents
pepe agent manage boss "*"

# a locked agent that cannot alter itself
pepe agent add child --can-manage none
```

Like routing, `can_manage` is a directed allowlist and it is deliberately not
symmetric. Giving `boss` authority over `sales` grants `sales` nothing at all over
`boss`. Authority only ever flows in the direction you wrote it, which is what lets you
put a locked, client-facing agent in front of an admin without the client agent being
able to reconfigure the admin, or itself.

## What manage_agent can do

| Action | What it does |
|--------|--------------|
| `list` | List the agents in scope. |
| `get` | Read one agent's configuration. |
| `create` | Create a new agent. |
| `set_persona` | Rewrite the target's system prompt. |
| `set_model` | Point the target at a different model connection. |
| `set_utility_model` | Set the cheap connection the target's chores run on, such as naming a conversation. An empty value turns it off, and the chores are then done without a model. |
| `set_flag` | Turn one of the target's switches on or off (`on`/`off`): `trust_untrusted_content` (let it act on content strangers send it) or `exempt_message_limit`. Turning `trust_untrusted_content` on cannot be done from a run that has itself taken in outside content, so an injected document cannot flip it. |
| `add_tool` | Grant the target one more tool. |
| `remove_tool` | Revoke a tool from the target. |
| `remember` | Append a fact to the target's memory. |

You do not need the flag names. `set_flag` is driven by the model, so you ask in plain words ("let the support agent act on the files clients send it", "stop limiting this agent's messages") and it picks the right switch.

Persona and memory live in the target's workspace. Tools and model live in its entry in
the configuration file.

## The permission gate

`manage_agent` is a risky tool, so every use of it is authorized through the permission
gate. The agent proposes the change, you approve it, and only then is it written. An
agent may only touch the agents inside its own `can_manage` scope, and a request to
manage anything outside that scope is refused.
