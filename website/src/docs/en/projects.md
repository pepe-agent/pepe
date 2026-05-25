---
title: Projects
description: Wall one tenant off from another so a single deployment can serve many clients whose data never crosses.
---

## What a project is

A project is an isolated tenant scope. One deployment can serve many clients, and
nothing crosses from one to another: not files, not routing, not model keys.

Every tenant is a project, including the one you get out of the box. A fresh
install has a single **default project** (slug `default`), and that is the project
every command uses when you omit `--project`. Single-tenant use is unchanged: bare
agent names resolve into the default project, so you never have to think about
projects until you want a second tenant. Add one only when you have to wall tenants
off from each other.

<div class="note"><strong>The default project is a normal project.</strong> It
shows up in <code>project list</code> like any other, it can be renamed, and it
carries its own billing. There is no special "root" scope with different rules;
omitting <code>--project</code> simply falls back to the default project.</div>

## The handle is the identity

An agent's real identity is its **handle**. In the default project the handle is
just the bare name (`sales`). In another project it is qualified as `project/name`
(`acme/sales`). The same bare name can be reused in every project, so `acme/sales`
and `globex/sales` are two different agents.

The handle is what addresses everything: routing, sessions, and channel bindings
all use it. Under the hood every project and every agent also carries a stable
internal id, and it is that id, not the mutable name, that routing, permissions,
defaults, and cron/bot/token bindings are recorded against. Renaming a project or
an agent just relabels it and moves its directory; every reference follows, so
nothing dangles.

### Files

An agent's workspace is `~/.pepe/projects/<slug>/agents/<name>/` and its project's
shared space is `~/.pepe/projects/<slug>/shared/`. Equally named agents in different
projects never write to the same directory, and a `shared/...` path can never leak
across tenants. The default project follows the same layout under its own slug
(`~/.pepe/projects/default/…`).

### Routing

`send_to_agent` never crosses a project boundary. A bare target name resolves to a
peer inside the sender's own project, and a hard guard refuses any cross-project
route even if an allowlist asks for one.

### Models and keys

An agent resolves its models inside its own project first, then falls back to the
default project. A project can therefore pin private provider keys that no other
project can see, or inherit one shared global provider. A project's agent or model
is never promoted to the global default, not even when it is the first one created.

## Creating and using a project

```bash
pepe project add acme --description "Acme Inc"
pepe project add globex
pepe project list

# agents, models and routes all take --project
pepe model add llm  --project acme --base-url ... --api-key '${ACME_KEY}' --model ...
pepe agent add sales   --project acme --prompt "..." --can-message support
pepe agent add support --project acme --prompt "..."
pepe agent route sales support --project acme   # both resolve inside acme

pepe agent list --project acme    # only Acme's
pepe agent list                   # only the default project
pepe agent list --all             # every project
pepe chat --project acme sales    # or: pepe run acme/sales "..."
```

## Renaming and removing

```bash
pepe project rename acme umbrella   # relabels it and moves its directory;
                                    # all bindings follow, since they are by id
pepe project remove acme            # refuses while it still owns agents
pepe project remove acme --force    # removes it, and drops its agents too
```

Because references are by id, renaming a project (or an agent) never breaks a route,
a token, a cron, or a bot binding. The name is a label; the id is what everything
points at.

## What it looks like in config

Projects live in a `"projects"` map keyed by a stable id, each entry carrying a
`slug` and a `name`, and a top-level `"default_project"` names the id that bare,
unqualified references fall back to.

```jsonc
"default_project": "p_1a2b3c4d",
"projects": {
  "p_1a2b3c4d": { "slug": "default", "name": "Default" },
  "p_5e6f7a8b": { "slug": "acme", "name": "Acme Inc", "default_model": "llm" }
},
"agents": {
  "assistant":    { "can_message": [] },          // default project
  "acme/sales":   { "can_message": ["acme/support"] },
  "acme/support": { "can_message": [] }
}
```

## Projects and channels

A Telegram bot bound to an agent in a project keeps its whole conversation inside
that project. A bot bound to an agent in the default project serves the default
project, exactly as it did before you added any second project at all.

## Spend and message caps

The project is also the unit that billing meters. Every model call is metered per
project, and a project can carry a monthly spend cap, a monthly customer-message
cap, and a billing markup, including the default project. See
[Billing & limits](../billing/) for how to set, clear, and reset those, and
[Agents](../agents/) for the agent fields that projects scope.
