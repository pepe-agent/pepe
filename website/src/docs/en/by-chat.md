---
title: Manage by chat
description: Let trusted agents configure Pepe from natural-language conversations.
---

Trusted agents can manage Pepe from a conversation when you grant the matching management tools. These actions are guarded because they change runtime state or expose access.

## Administering agents

`can_manage` controls which agents an agent may administer (create, edit,
reconfigure, train) through the `manage_agent` tool. It is closed by default and its
meaning is precise:

- Unset (`null`): the agent may manage only itself.
- Empty (`[]`, set with `--can-manage none`): it may manage nobody, not even itself.
  A locked child, for example a client-facing agent that must not alter itself.
- A list of names: exactly those agents, and no others. Include its own name to let
  it manage itself too.
- `["*"]` (set with `--can-manage "*"`): every agent. An explicit super-admin.

Grant management authority directly:

```bash
pepe agent manage supervisor "*"
```

### Do it by chat

An admin agent uses `manage_agent` to shape the agents in its scope. Its actions are
`list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`, `remove_tool`, and
`remember` (append a durable fact to the target's memory). For example:

```text
Give the support agent the send_file tool and add a note to its memory that
refunds over 200 need a human.
```

The agent calls `manage_agent` with `action: "add_tool"` and then
`action: "remember"`. Every one of these actions is gated: the agent proposes the
change, you authorize it, and only then is it applied. An agent can also rename
itself with the separate `rename_agent` tool ("From now on, call yourself scout"),
which moves its workspace directory and takes effect on the next message.
