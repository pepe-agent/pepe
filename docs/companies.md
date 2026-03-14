# Companies (multi-tenant isolation)

Optional. A **company** is an isolated tenant scope, so one deployment can serve
many clients whose data never crosses. It is entirely opt-in: with no company,
everything lives in the **root** scope - identical to a single-tenant install - and
that's what every command uses without `--company`. Most deployments never need a
company; add one only when you must wall tenants off.

An agent's identity is a **handle**: a bare name in root (`vendas`) or
`company/name` inside a company (`acme/vendas`). The same bare name can be reused
per company - `acme/vendas` and `globex/vendas` are different agents. Because the
handle is what keys everything (config, workspace, sessions, routes), isolation
follows automatically:

- **Files** - a company agent's workspace is `~/.pepe/companies/<co>/agents/<name>/`
  and its shared space is `~/.pepe/companies/<co>/shared/`, so equally named agents
  in different companies never collide and `shared/...` paths never leak across tenants.
  Root agents keep `~/.pepe/agents/<name>/` and `~/.pepe/shared/`.

- **Routing** - `send_to_agent` never crosses companies: a bare target resolves to a
  peer in the sender's own company, and a hard guard refuses any cross-company route
  even if an allowlist asks for it.

- **Models/keys** - a company agent resolves its own models first, then root, so a
  company can pin private provider keys other companies can't see - or inherit one
  shared global provider. A company agent/model never becomes the global default.

```bash
mix pepe company add acme --description "Acme Inc"
mix pepe company add globex
mix pepe company list

# agents, models, routes all take --company
mix pepe model add llm  --company acme --base-url ... --api-key '${ACME_KEY}' --model ...
mix pepe agent add vendas  --company acme --prompt "..." --can-message suporte
mix pepe agent add suporte --company acme --prompt "..."
mix pepe agent route vendas suporte --company acme   # both resolve inside acme

mix pepe agent list --company acme    # only Acme's
mix pepe agent list                   # only root
mix pepe agent list --all             # every scope
mix pepe tui --company acme vendas    # or: mix pepe run acme/vendas "..."

mix pepe company rename acme umbrella # re-keys its agents, models, routes,
                                      # crons, watches, bots, tokens and files
mix pepe company remove acme          # refuses while it owns agents...
mix pepe company remove acme --force  # ...unless forced (drops its agents too)
```

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // root scope
  "acme/vendas":  { "can_message": ["acme/suporte"] },
  "acme/suporte": { "can_message": [] }
}
```

A Telegram bot bound to a company agent keeps its whole conversation inside that
company; without a company it serves root, as before.

---

[Back to the docs index](../README.md#documentation)
