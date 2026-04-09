# Plugins - community tools and channels

A **plugin** is drop-in Elixir (`.exs`) that adds a **tool** you can call or a
**channel** (a webhook provider) - compiled at runtime, no rebuild. You can install
one yourself from chat with the `manage_plugin` tool instead of asking the user to
run the CLI.

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
