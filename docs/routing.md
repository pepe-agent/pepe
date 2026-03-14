# Agent-to-agent routing

Agents can message each other through the `send_to_agent` tool, governed by a
**directed allowlist** - each agent's `can_message` lists who *it* may message, so
`A -> B` does **not** imply `B -> A`. The called agent answers in a fresh run and its
reply comes back as the tool result; a hop limit and cycle check stop chains from
looping.

```bash
# A can message B; B can message C and D; C can message A and B
mix pepe agent route A B
mix pepe agent route B C
mix pepe agent route B D
mix pepe agent route C A
mix pepe agent route C B
mix pepe agent route A B --remove        # revoke a route

# or set it when creating the agent
mix pepe agent add A --model mock --can-message B
```

```jsonc
"agents": {
  "A": { "can_message": ["B"] },
  "B": { "can_message": ["C", "D"] },
  "C": { "can_message": ["A", "B"] }
}
```

Add `send_to_agent` to an agent's `tools` to let it route. The route allowlist is
the authorization, so the call itself isn't put through the human permission gate -
but the callee's own risky tools still are.

Routes can also be changed **from chat**: give an agent the `set_route` tool and it
can add/remove routes (`{from, to, action}`, `from` defaults to itself) - guided by
the `manage-routing` skill. Since it edits config, the change goes through the
permission prompt.

---

[Back to the docs index](../README.md#documentation)
