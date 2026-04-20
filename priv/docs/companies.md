# Companies - multi-tenant isolation

A **company** is an isolated tenant scope, so one Pepe deployment can serve many
clients whose data never crosses. It's entirely opt-in: with no company everything
lives in the **root** scope - identical to a single-tenant install - and that's what
every command and agent uses without `--company`. Most deployments never need one;
add a company only when you must wall tenants off.

## The handle is the identity

An agent's identity is a **handle**: a bare name in root (`support`) or
`company/name` inside a company (`acme/support`). The same bare name can be reused
per company - `acme/support` and `globex/support` are different agents. Because the
handle keys *everything* - config, workspace directory, session keys, routes, cron
and bot bindings - isolation follows automatically:

- **Files** - a company agent's workspace is `~/.pepe/companies/<co>/agents/<name>/`
  and its shared space is `~/.pepe/companies/<co>/shared/`, so equally named agents
  never collide and `shared/...` paths never leak across tenants. Root agents keep
  `~/.pepe/agents/<name>/` and `~/.pepe/shared/`.
- **Routing** - `send_to_agent` never crosses companies: a bare target resolves to a
  peer in the sender's own company, and a hard guard refuses any cross-company route
  even if an allowlist asks for it.
- **Models/keys** - a company agent resolves its own models first, then root, so a
  company can pin private provider keys others can't see, or inherit one shared global
  provider. A company agent or model never becomes the global default.
- **API tokens** - a company-scoped token reaches only that company's agents (see
  `authentication`).

## The root scope is the default

The **root** scope (`company == nil`) is the Principal, top-level scope every command
operates on when no `--company` is given. A single-tenant install is just root with no
companies at all - nothing about companies is in your way until you create one.

## Managing companies - CLI, not a tool

There is **no dedicated `manage_company` tool** - company lifecycle is a CLI-only
operation, so you'd run it via `bash` (or the owner `manage_pepe` power-tool) rather
than a structured tool call. The commands:

```bash
mix pepe company add acme --description "Acme Inc"   # create an isolated tenant
mix pepe company list                                # list companies (root is implicit)
mix pepe company rename acme umbrella                # re-keys its agents, models,
                                                     # routes, crons, bots, tokens, files
mix pepe company remove acme                         # refuses while it owns agents...
mix pepe company remove acme --force                 # ...unless forced (drops them too)
```

Agents, models, routes and tokens all take `--company` to act inside one:

```bash
mix pepe agent add support --company acme --prompt "..." --model llm
mix pepe agent list --company acme    # only Acme's
mix pepe agent list                   # only root
mix pepe agent list --all             # every scope
mix pepe run acme/support "hello"     # run a company agent by full handle
```

You don't "switch context" mid-conversation - a request already carries its scope
(the calling agent's own handle, or an API token's company). To act on another
company's agents you address them by full handle where a command allows it, subject to
the same isolation guards above.
