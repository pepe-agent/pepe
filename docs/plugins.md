# Plugins

A **plugin** extends Pepe without rebuilding it, compiled at runtime from
`<PEPE_HOME>/plugins/` (default `~/.pepe/plugins/`). It can add a **tool** the agent can
call, or a **channel** (a webhook provider), or both. Built-in pieces and plugins are
merged, and a plugin with the same name wins.

A plugin is one of two shapes:

- a **bare `.exs` file** (dropped straight in the plugins dir), or
- a **package**: a directory with a `manifest.json` and one or more `.exs` files. The
  manifest names the plugin and describes it:

  ```json
  { "name": "chatwoot", "version": "0.1.0",
    "description": "...", "provides": ["channel:chatwoot"], "files": ["chatwoot.exs"] }
  ```

```bash
mix pepe plugin list                              # what's installed and what it adds
mix pepe plugin install ./some/dir                # a local directory
mix pepe plugin install ./plugin.tar.gz           # a local archive
mix pepe plugin install https://github.com/you/repo   # a GitHub repo
mix pepe plugin install https://host/plugin.tar.gz    # a remote archive
mix pepe plugin remove NAME                       # delete one
```

An agent holding the `manage_plugin` tool can do the same from a conversation
(`scan`/`install`/`list`/`remove`), useful when you'd rather ask than open a
terminal. It runs the same scan below, but with no `--force`: a dangerous
verdict is always refused from chat, on purpose.

`install` unrolls the source into the plugins dir. A **GitHub repo URL** is fetched as its
source archive (the default branch, `main` then `master`; add `/tree/<branch>` for another)
and extracted; a `.tar.gz` (local or a URL) is extracted and the package placed under its
manifest `name`; a directory is copied in; a bare `.exs` is copied straight. Every `.exs`
under the plugins dir is compiled once and cached (recompiled only when it changes), so a
new plugin is picked up on the next run without a rebuild.

## What a plugin looks like

- A **tool** module exports `name/0`, `spec/0`, `run/2` (the `Pepe.Tools.Tool` shape). It
  then appears in `mix pepe tools` and can be added to an agent's tool list.
- A **channel** module exports `name/0` plus the `Pepe.Webhooks.Provider` callbacks
  (`verify/2`, `authenticate/3`, `parse/1`, `deliver/3`), and optionally `label/0` and
  `config_schema/0` for the dashboard. It then serves under the existing webhook route
  `/webhooks/:company/:provider/:slug`, no new route needed.

See `examples/plugins/chatwoot/` in the repo for a complete channel plugin package.

## Security scan on install

Before a plugin is placed, its Elixir code is scanned by `Pepe.Skills.Sentinel`, which
walks the **parse tree** (not just text) and flags dangerous calls precisely: shelling out
(`System.cmd`, `:os.cmd`), dynamic eval (`Code.eval_string`), unsafe deserialization
(`:erlang.binary_to_term`), destructive filesystem (`File.rm_rf`), atom exhaustion
(`String.to_atom`), reading the environment or secret paths (`~/.ssh`, the Pepe config),
and network. Because it reads the AST it catches aliased and Erlang forms too, and it does
not trip over the same words in comments or strings. A **danger** verdict refuses the
install unless you pass `--force`; **caution** findings (e.g. a channel plugin using the
network) are shown but do not block. Scan without installing with `mix pepe plugin scan SRC`.

## Two honest limits

1. **A plugin is trusted code.** The scan is a fast static check, not a proof of safety.
   A plugin still runs with the same access as the app (network, disk, everything), so
   installing one is a trust decision, like adding any dependency, install only from a
   source you trust, and prefer pinning a specific version/commit.
2. **No new external dependencies at runtime.** Elixir resolves and compiles dependencies
   at build time, so a plugin can only use libraries Pepe already ships (`Req`, `Jason`,
   the standard library, ...). A plugin that needs a brand-new library cannot be a
   drop-in, it would require rebuilding Pepe. Channel plugins like Chatwoot only need what
   is already bundled, so they install cleanly.

## Example: Chatwoot channel

`examples/plugins/chatwoot/chatwoot.exs` registers a `chatwoot` provider so Pepe can sit behind a
[Chatwoot](https://www.chatwoot.com) inbox as the AI agent, across every channel Chatwoot
owns (WhatsApp, web widget, Instagram, ...). Install it:

```bash
mix pepe plugin install examples/plugins/chatwoot
```

**Native human handoff (no external glue).** Chatwoot carries the handoff signal in every
webhook: the conversation `status`. The plugin answers only conversations Chatwoot marks
`pending` (bot-owned). The moment a human agent takes the conversation (`open`), Pepe goes
quiet; when it returns to `pending`, the agent resumes. Nothing else to wire.

**Setup (in Chatwoot):** create an AgentBot and point its outgoing webhook at the
connection URL, `https://YOUR_HOST/webhooks/<company>/chatwoot/<slug>`. The connection
holds the Chatwoot `base_url`, `account_id` and an `api_token` (store it as `${ENV_VAR}`).
Configuring the connection from the dashboard is covered in the Channels section.

> This is one of two mutually exclusive ways to run WhatsApp: **either** WhatsApp direct
> in Pepe (the built-in `whatsapp` provider, no Chatwoot) **or** WhatsApp on Chatwoot with
> Pepe behind it (this plugin). Do not connect the same number to both.

---

[Back to the docs index](../README.md#documentation)
