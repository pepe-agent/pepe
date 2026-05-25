# Projects - multi-tenant isolation

A **project** is an isolated tenant scope, so one Pepe deployment can serve many
clients whose data never crosses. Every tenant is a project, including the one you
start with: a normal, renameable **default project** (slug `default`) that every
command and agent falls back to when none is named. A single-tenant install is just
the default project on its own, and bare agent names keep working exactly as before -
you only add another project when you must wall tenants off.

## The handle is the identity

An agent's identity is a **handle**: a bare name in the default project (`support`)
or `project/name` inside a named one (`acme/support`). The same bare name can be
reused per project - `acme/support` and `globex/support` are different agents. Because
the handle keys *everything* - config, workspace directory, session keys, routes, cron
and bot bindings - isolation follows automatically:

- **Files** - a project agent's workspace is `~/.pepe/projects/<slug>/agents/<name>/`
  and its shared space is `~/.pepe/projects/<slug>/shared/`, so equally named agents
  never collide and `shared/...` paths never leak across tenants. Default-project
  agents live under `~/.pepe/projects/default/agents/<name>/` and
  `~/.pepe/projects/default/shared/`.
- **Routing** - `send_to_agent` never crosses projects: a bare target resolves to a
  peer in the sender's own project, and a hard guard refuses any cross-project route
  even if an allowlist asks for it.
- **Models/keys** - a project agent resolves its own models first, then the default
  project, so a project can pin private provider keys others can't see, or inherit one
  shared global provider. A non-default project's agent or model never becomes the
  global default.
- **API tokens** - a project-scoped token reaches only that project's agents (see
  `authentication`).

## The default project is the fallback

The project with slug `default` is a real, first-class project - not a special "no
scope". It's the one every command operates on when no `--project` is given, and it
can be renamed and relabelled like any other. A single-tenant install is just the
default project with no siblings - nothing about projects is in your way until you
create a second one.

## Stable ids - names are just labels

Every project has a stable internal **id** and a mutable `slug`/`name` label; agents
have a stable id too. Renaming a project or an agent only relabels it and moves its
directory - every reference (routing, permissions, defaults, cron/bot/token bindings)
is stored **by id**, so nothing dangles when a name changes. The top-level
`default_project` pointer is also an id, so relabelling the default project keeps it
the default.

## Managing projects - CLI, not a tool

There is **no dedicated `manage_project` tool** - project lifecycle is a CLI-only
operation, so you'd run it via `bash` (or the owner `manage_pepe` power-tool) rather
than a structured tool call. The commands:

```bash
mix pepe project add acme --description "Acme Inc"   # create an isolated tenant
mix pepe project list                                # list projects (default included)
mix pepe project rename acme umbrella                # relabels it + moves its dir;
                                                     # every id-based reference follows
mix pepe project remove acme                         # refuses while it owns agents...
mix pepe project remove acme --force                 # ...unless forced (drops them too)
```

Agents, models, routes and tokens all take `--project` to act inside one:

```bash
mix pepe agent add support --project acme --prompt "..." --model llm
mix pepe agent list --project acme    # only Acme's
mix pepe agent list                   # only the default project
mix pepe agent list --all             # every project
mix pepe run acme/support "hello"     # run a project agent by full handle
```

You don't "switch context" mid-conversation - a request already carries its scope
(the calling agent's own handle, or an API token's project). To act on another
project's agents you address them by full handle where a command allows it, subject to
the same isolation guards above.
