# Plugins - community tools and channels

A **plugin** is drop-in Elixir (`.exs`), compiled at runtime, no rebuild. It can add
a **tool** you can call, a **channel** (a webhook provider), an **HTTP route** of its
own (`Pepe.PluginRoute` - an OAuth callback, a custom endpoint), a **realtime audio
provider** (`Pepe.Realtime.Provider`), a **hook** (mutates message content), a
**policy** (can veto a tool call or a whole run), a **run observer** (read-only
monitoring), or occupy a **slot** (`memory`/`web_search`/`sandbox`/`compaction`/
`harness`). You can install one yourself from chat with the `manage_plugin` tool
instead of asking the user to run the CLI.

## How each kind gets turned on

Not every plugin kind needs the same step after `manage_plugin install` -
installing is not the same as enabling:

- **Tool**: needs an explicit grant - see "After installing, grant the tool" below.
- **Hook**: also per-agent, but via `hooks`, not `tools` - `manage_agent` with
  `hooks: ["the_hook_name"]`, or the operator adding it on the dashboard's agent
  form. An agent with no `hooks` runs completely unaffected by any installed hook.
- **Slot** (`memory`/`web_search`/`sandbox`/`compaction`/`harness`): installation-wide
  by default (`mix pepe slot set NAME PLUGIN`, or `slots` in `config.json`), but can
  be overridden per agent (`mix pepe agent add NAME --slots memory:PLUGIN`) or per
  project (`default_slots`) - resolution is agent -> project -> installation-wide ->
  builtin. Pinning `harness` is a bigger decision than the others: it hands that
  plugin the whole turn, not just one call - see its own manifest/docs before
  suggesting it.
- **HTTP route** (`Pepe.PluginRoute`): a **second, explicit** opt-in beyond
  installing, and **operator-only** - `mix pepe plugin route enable NAME` at the
  terminal, never from chat. `manage_plugin`'s `route_list` action shows what's
  claimed/enabled (read-only); there is no `route_enable` action on purpose, unlike
  every other action on that tool - a route answers *any* inbound request, not one you
  decided to make, so it's not something to ask a human to approve mid-conversation the
  way an install is. Point the user at the CLI command if they want one turned on.
- **Realtime audio provider** (`Pepe.Realtime.Provider`): no grant at all - a client
  picks one by name when it connects to `PepeWeb.RealtimeChannel`
  (`realtime:<agent_name>`, join payload `{"provider": "NAME"}`). Several can be
  installed at once; nothing "enables" one globally.
- **Policy**: no grant of any kind, and an agent can never opt itself out of one -
  that would defeat the whole point of it being fail-closed. The *operator* can
  still narrow which agents/projects a policy is even consulted for
  (`mix pepe policy scope NAME --agents a,b --projects x,y`, or `policy_scope` in
  `config.json`) - unscoped (the default) means every agent. A policy's optional
  `check_run/3` vetoes a whole run, before the first model call, same scope rules.
- **Run observer**: no grant, no scoping at all - installed means active, for
  every agent, immediately. It's strictly read-only, so there's nothing an agent
  could opt out of that would matter, and no reason an operator would need to
  narrow where it watches.

If the user asks you to "turn on" a plugin and you're not sure which kind it is,
`manage_plugin list` or the plugin's own manifest tells you - don't guess from the
name alone (a hook and a tool can plausibly share a similar-sounding name).

## Install (the `manage_plugin` tool)

1. **scan** - security-scan a source *before* installing it, so you can tell the
   user what it does:

   ```
   manage_plugin scan  src: "https://github.com/someone/pepe-weather"
   ```

2. **install** - fetch and place it. `src` is a local path, a `.tar.gz`, or an
   http(s)/GitHub URL:

   ```
   manage_plugin install  src: "https://github.com/someone/pepe-weather"
   ```

   The install itself re-scans with `Pepe.Skills.Sentinel`. A `danger` verdict is
   **always refused** - there is no `force` from chat. Tell the user what was
   flagged and, if they've reviewed the code themselves and still want it, point
   them at `mix pepe plugin install SRC --force` in a terminal. Never suggest they
   ask you to bypass it - that decision is not yours to make on their behalf.

3. **list** / **remove** - manage what's installed.

## After installing, grant the tool

Installing a plugin does not hand its tools to any agent automatically. A new tool
appears in the registry (`mix pepe tools` / `Pepe.Tools.names/0`), but an agent only
gets to call it once it's on that agent's `tools` list - use `manage_agent`
`add_tool`, or the user can tick it on the dashboard. Same permission gate as any
other tool after that: a plugin tool is not in the always-safe set, so its first
call still asks for authorization unless pre-approved.

A channel plugin needs no such grant - once installed it's reachable at the
existing webhook route immediately, see `channels`.

## Verify

`manage_plugin list` after an install should show the new package. If a tool
doesn't appear where you granted it, check the plugin actually exports the right
shape (`name/0`, `spec/0`, `run/2` for a tool) - a malformed `.exs` just fails to
load silently into the registry.
