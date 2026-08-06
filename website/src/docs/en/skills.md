---
title: Skills
description: Install reusable instructions that teach agents repeatable workflows.
---

A skill is an on-demand instruction doc: a Markdown file that teaches an agent a
*procedure*, such as how to install a tool or how to deal with an audio message.
Skills are how an agent learns to do something new without a single line of code
changing.

## Listed, not loaded

A skill is never pasted into the system prompt in full. Only its name and a
one-line summary are listed in the agent's context. When the topic comes up, the
agent calls the `skill` tool with that name, reads the whole document, and
follows it.

That is what keeps skills cheap. An agent can know dozens of procedures
without them weighing the conversation down, because each one costs a single
line until the moment the work actually calls for it. The summary is simply the
first non-empty line of the file, so that opening line should say when the
skill applies.

<div class="note"><strong>The skill tool.</strong> An agent needs the <code>skill</code> tool in its tool list to read skills. Without it the skills are listed in its context but never opened.</div>

## Built-in skills

These ship with Pepe, under `priv/skills/`:

- **`skill-creator`**: how to create, edit, audit and improve skills (the meta-skill).
- **`install-tool`**: write a plugin tool and enable it from chat.
- **`write-a-script`**: solve complex tasks by writing and saving a program to run.
- **`manage-routing`**: change agent-to-agent routes with `set_route`.
- **`handle-media`**: understand a voice, audio, image or file input (transcribe, read), installing whatever it needs.
- **`install-skill`**: install a skill from a URL, a gist, a repo, or another Pepe.
- **`create-watch`**: set up a durable "check X and notify me when it happens" watch.

## Writing your own

User skills live in `~/.pepe/skills/*.md`. A user skill overrides a built-in of
the same name, so writing a `handle-media.md` of your own replaces the one that
ships with Pepe. The first non-empty line is the summary; everything after it is
the procedure, in plain Markdown, written for the agent to read and follow.

```bash
~/.pepe/skills/cut-a-release.md
```

There is no registration step and no restart. Drop the file in and the skill
appears in the agent's list on its next message.

### Let the agent write it

An agent can author its own skills. Ask it to remember how to do something as a
skill and, guided by `skill-creator`, it writes a new `skills/<name>.md` that
shows up in its own list right away.

> You: that worked. remember how to cut a release as a skill
>
> Agent: saved skills/cut-a-release.md. I will follow it the next time you ask for a release.

This is what makes an agent's know-how durable. A procedure it worked out once
gets written down instead of being rediscovered every session.

### Installing one from elsewhere

The `install-skill` skill teaches an agent to pull a skill from a URL, a gist, a
repo, or another Pepe instance. Skill text from outside is untrusted input, so
the agent security-scans it with the `scan_skill` tool before writing it to
disk. The scan flags prompt injection, secret exfiltration, destructive
commands, persistence and obfuscation. It is a second check rather than a
substitute for reading the content, and it never installs anything itself.

## Installing from a marketplace

`install-skill` (above) is the conversational path: an agent pulls one skill from a link you
give it. `mix pepe skill` is the operator path, with a registry to search and an update story:

```bash
pepe skill search release            # search every tap plus the bundled registry
pepe skill install cut-a-release     # install by name
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # or directly
pepe skill update cut-a-release      # re-fetch from the exact source it was installed from
pepe skill tap add https://github.com/your-team/pepe-skills   # add a registry beyond the bundled default
```

Every install goes through the same static security scan `install-skill` uses; a dangerous
verdict is refused unless you pass `--force`. Trust is `"official"` only for the bundled,
in-repo registry (curated by Pepe's own maintainers, empty by default today: there is no
hosted registry yet, only the mechanism). Anything resolved through a tap you added, or
installed with `--source`, is `"community"`: when an agent reads it with the `skill` tool,
its content is wrapped in the same untrusted-content marker a fetched web page carries, until
you've reviewed it yourself.

`update` is pinned to the exact source a skill was installed from. If a tap's registry later
points that name at a *different* source, `update` refuses rather than silently following it.
A same-named skill from elsewhere can only replace an installed one via an explicit
`install --force`, never a routine update.

## Skills, plugins and scripts

Skills, plugins and scripts work together, and that combination is what lets
you ask an agent in plain language for something it cannot do yet.

Combined with [plugins](../plugins/) and `enable_tool`, an agent can be told in
chat to install a tool that does X. It reads the `install-tool` skill, writes
the plugin to `plugins/<name>.exs`, enables the tool on itself, and starts
calling it, with no restart.

For complex or multi-step work an agent does not grind through it by hand. The
`run_script` tool lets it write a short program (Python, Node, Ruby, Bash or
Elixir, and Elixir is always available) and run it, getting back stdout, stderr
and the exit code so it can iterate on the errors. Worthwhile scripts are saved
under `scripts/` and re-run later by passing `run_script` a `file:` reference.
When the agent works out *how* to do a recurring task, reading a PDF or
crunching a spreadsheet, it writes itself a skill under `skills/<name>.md`. The
`write-a-script` skill teaches that whole loop.
