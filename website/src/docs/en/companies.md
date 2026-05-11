---
title: Companies
description: Wall one tenant off from another so a single deployment can serve many clients whose data never crosses.
---

## What a company is

A company is an isolated tenant scope. One deployment can serve many clients, and
nothing crosses from one to another: not files, not routing, not model keys.

Companies are entirely opt-in. With no company at all, everything lives in the
**root** scope, which behaves exactly like a single-tenant install, and root is the
scope every command uses when you omit `--company`. Most deployments never need a
company. Add one only when you have to wall tenants off from each other.

<div class="note"><strong>In the dashboard.</strong> Root is shown as "Principal",
and the Companies page lists every real company you have created. Root is not a real
company: it never appears in <code>company list</code>, and it cannot be renamed or
removed.</div>

## The handle is the identity

An agent's real identity is its **handle**. In root the handle is just the bare name
(`sales`). Inside a company it is qualified as `company/name` (`acme/sales`). The
same bare name can be reused in every company, so `acme/sales` and `globex/sales` are
two different agents.

The handle is what keys everything: the config entry, the workspace directory, the
sessions, and the routes. Because of that, isolation is not a separate feature bolted
on top. It follows from the handle.

### Files

A company agent's workspace is `~/.pepe/companies/<company>/agents/<name>/` and its
shared space is `~/.pepe/companies/<company>/shared/`. Equally named agents in
different companies never write to the same directory, and a `shared/...` path can
never leak across tenants. Root agents keep the plain layout, `~/.pepe/agents/<name>/`
and `~/.pepe/shared/`.

### Routing

`send_to_agent` never crosses a company boundary. A bare target name resolves to a
peer inside the sender's own company, and a hard guard refuses any cross-company
route even if an allowlist asks for one.

### Models and keys

A company agent resolves its models inside its own company first, then falls back to
root. A company can therefore pin private provider keys that no other company can
see, or inherit one shared global provider. A company's agent or model is never
promoted to the global default, not even when it is the first one created.

## Creating and using a company

```bash
pepe company add acme --description "Acme Inc"
pepe company add globex
pepe company list

# agents, models and routes all take --company
pepe model add llm  --company acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --company acme --prompt "..." --can-message support
pepe agent add support --company acme --prompt "..."
pepe agent route sales support --company acme   # both resolve inside acme

pepe agent list --company acme    # only Acme's
pepe agent list                   # only root
pepe agent list --all             # every scope
pepe chat --company acme sales    # or: pepe run acme/sales "..."
```

## Renaming and removing

```bash
pepe company rename acme umbrella   # re-keys its agents, models, routes,
                                    # crons, watches, bots, tokens and files
pepe company remove acme            # refuses while it still owns agents
pepe company remove acme --force    # removes it, and drops its agents too
```

## What it looks like in config

```jsonc
"companies": { "acme": { "description": "Acme Inc", "default_model": "llm" } },
"agents": {
  "assistant":    { "can_message": [] },          // root scope
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Companies and channels

A Telegram bot bound to a company agent keeps its whole conversation inside that
company. A bot bound to a root agent serves root, exactly as it did before you had
any company at all.

## Spend and message caps

The company is also the unit that billing meters. Every model call is metered per
company, and a company can carry a monthly spend cap, a monthly customer-message cap,
and a billing markup. See [Billing & limits](../billing/) for how to set, clear, and
reset those, and [Agents](../agents/) for the agent fields that companies scope.
