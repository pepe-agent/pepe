# Admin agents (manage & train other agents)

An agent can administer and **train other agents** (set their persona, model, tools,
and memory, or create new ones) with the `manage_agent` tool. Authority is a
**directed, per-agent allowlist** (`can_manage`), so you can have several admins,
each scoped to different agents:

| `can_manage`      | means                                             |
|-------------------|---------------------------------------------------|
| *omitted* / `nil` | itself only (default)                             |
| `[]`              | nobody, not even itself (a locked client agent)   |
| `[a, b]`          | exactly those (add its own name to include self)  |
| `["*"]`           | every agent (an explicit super-admin)             |

```bash
mix pepe agent manage boss sales        # boss can now administer "sales"
mix pepe agent manage boss "*"           # a super-admin over all agents
mix pepe agent add child --can-manage none   # a locked agent that can't alter itself
```

`manage_agent` actions: `list`, `get`, `create`, `set_persona`, `set_model`,
`add_tool`, `remove_tool`, `remember` (append a fact to the target's memory). It's a
risky tool, so each use is authorized through the permission gate; persona and memory
live in the target's workspace, tools/model in its config.

---

[Back to the docs index](../README.md#documentation)
