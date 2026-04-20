# Skills - on-demand how-to procedures

A **skill** is a step-by-step how-to Markdown file that teaches you a *procedure* -
how to actually *do* something (install a tool, handle a media file, create a watch).
This is distinct from `docs`, which are reference/conceptual ("what is X, how does it
work"). Skills are listed (name + a one-line summary) in your context, but their full
text is **not** loaded into every prompt - you read the relevant one with the `skill`
tool when its topic comes up, keeping context lean.

## Read a skill (`skill`)

When a request matches a listed skill, read it first, then follow it:

```
skill name: "install-tool"
```

The `name` is the skill's filename without `.md`, taken from the list in your context.
It returns the full procedure. Don't guess the steps - read the skill and do what it
says.

## Built-in vs user skills

- **Built-in** skills ship under `priv/skills/*.md` - always available. The current
  set: `skill-creator` (the meta-skill: create/edit/audit/improve a skill),
  `install-tool`, `install-skill`, `write-a-script`, `manage-routing`, `handle-media`,
  and `create-watch`.
- **User** skills live under `<PEPE_HOME>/skills/*.md` (i.e. `~/.pepe/skills/`) and
  **override a built-in of the same name**. The first non-empty line is the summary;
  the rest is the procedure.

## Authoring a new skill

You can write your own skills. When you work out *how* to do a recurring task, save it
as `skills/<name>.md` in your workspace - it then appears in your skills list with no
restart. Read the built-in **`skill-creator`** skill first; it's the guide for
creating, editing, auditing, and improving a skill. The user can also just say
"remember how to do X as a skill" and you author one, guided by `skill-creator`.

## Vet an untrusted skill before installing (`scan_skill`)

When you fetch a skill from an external source (a URL, gist, repo, or another Pepe),
run it through the static security scanner **before** you `write_file` it:

```
scan_skill content: "<the skill's full Markdown text>"
```

It flags prompt injection, secret exfiltration, destructive commands, persistence, and
obfuscation. It's read-only - it never installs anything itself. Treat it as a second
check, **not** a replacement for reading the content yourself. The `install-skill`
skill walks the whole install flow (fetch -> scan -> read -> save).
