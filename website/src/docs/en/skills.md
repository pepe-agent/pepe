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
skill applies. A skill can also state its summary in a metadata header instead,
which is what makes skills written elsewhere work here unchanged (see
[A format other tools share](#a-format-other-tools-share) below).

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

### Learning without being asked

Asking for a skill is something that occurs to nobody in the middle of the task they
actually wanted done, so most procedures never get written down at all. The
`skill_learning` flag, off by default, closes that gap from the other side: Pepe watches
what a turn really did, and on the turns that earned it the agent may raise the subject
itself.

* **A procedure worth keeping.** The task took at least four successful tool calls across
  at least two different tools, and no existing skill was consulted. The agent may end its
  reply with one sentence offering to save what it just worked out.
* **A skill that turned out to be wrong.** The agent read a skill and something after it
  failed. Its instructions led somewhere that did not work, so the agent may offer to
  correct that skill with what the failure taught it: an edit to the skill that already
  exists, never a second one under a new name.

Offering is all it does. Nothing is written or changed until you say yes, and a quick
lookup, a retry loop on a single tool, or a task an existing skill already covered goes by
in silence.

```bash
pepe agent add ops --skill-learning ...
```

Turn it on for an agent whose know-how should accumulate, and leave it off when the skill
library is curated by hand. The same switch is in the dashboard's agent editor, and an
agent with the `manage_agent` tool can set `skill_learning` on another.

### Tidying up after itself

An agent that writes its own skills eventually piles up a few nobody goes back to clean
up. The curator does that on a schedule, and only ever to a skill an agent wrote on its
own: a skill you wrote by hand, installed, or pinned is never touched, whatever state it's
in.

On by default, it makes two passes:

- **A deterministic pass, no model call.** An agent-written skill moves through `active`
  &rarr; `stale` &rarr; `archived` purely on how long it has gone unused (stale after 14
  days, archived after 30, both configurable). Used again while stale, it goes back to
  active. Archiving moves it into `.archive/` - nothing is deleted, and `pepe skill
  restore` brings it back.
- **An optional model pass** (`consolidate`, off by default because it spends a run):
  merges overlapping narrow skills into broader ones, through the same reviewed, scanned
  `manage_skill` path as any other skill edit.

It runs at most once a week, and only once nothing has happened in any conversation for a
couple of hours - never mid-work. Before it changes anything it snapshots the whole skill
library, so a run is always reversible:

```bash
pepe skill curator status                  # last run, next run, counts
pepe skill curator run --dry-run           # see what it would do, change nothing
pepe skill curator run --consolidate       # also merge overlapping skills, just this once
pepe skill curator pause                   # stop it from starting another run on its own
pepe skill curator backup                  # snapshot the library by hand
pepe skill curator rollback [ID]           # restore the last snapshot (or a named one)
pepe skill curator settings                # stale_after_days, archive_after_days, etc.
pepe skill curator set archive_after_days 45
```

A single run never archives more than half the library (or 20 skills, whichever is
larger) unless you pass `--force` - a guardrail against a misconfigured threshold, or a
big batch of skills all going idle at once, taking out the library before anyone notices.
It also leaves alone any skill that was edited by hand outside `manage_skill`, since that
edit was never reviewed by anything the curator trusts. Turn it off entirely with `pepe
skill curator set enabled false`. It's CLI-only for now - there's no dashboard or
conversational control for it yet.

### Packaging a skill with scripts

A skill can also ship as a small package instead of a single file: a `<name>/`
directory holding `SKILL.md` (its entry doc, read exactly like a loose
`<name>.md`) alongside whatever else it needs, typically a `scripts/` folder.

```bash
~/.pepe/skills/cut-a-release/
  SKILL.md
  scripts/tag-and-push.sh
```

The bundled files are never copied anywhere: an agent reaches them in place,
the same way it already reaches the shared workspace or an installed plugin,
by giving `run_script` (or `read_file`) a path shaped
`skills/<name>/scripts/<file>`. Point `SKILL.md`'s own instructions at that
path and the script runs exactly as shipped, instead of the agent
re-authoring it from scratch on the first request of every session.

A skill installed through `manage_skill`/`mix pepe skill install` (below)
brings its whole package along automatically when the source has one: a
`SKILL.md` at the root of what's installed is what marks it as a package;
anything without one still installs as a single `<name>.md`, exactly as
before. Every file in a package is security-scanned before install, not just
the doc: `SKILL.md` gets the usual prompt-injection scan, and each bundled
script gets the same deep scan a plugin's code gets.

### A format other tools share

Plenty of agent tools now publish skills in the same shape Pepe uses: a folder
with a `SKILL.md` in it. Their files open with a `---` fenced YAML header
carrying at least a `name` and a `description`, and that `description` is the
summary. Pepe reads that header, so a skill written for any of those tools
works here as it is, with nothing to convert.

```markdown
---
name: read-pdf
description: Extracts text and tables from PDFs. Use when the user sends a PDF.
---

Run `scripts/extract.py` with the path.
```

The header is optional, and nothing about existing skills changes: with no
header, the first non-empty line is still the summary. Use the header when a
skill is meant to travel, because a skill of yours that carries one is equally
readable by every other tool that speaks the format. Keys beyond `name` and
`description` (`license`, `compatibility`, `metadata`) are kept in the file and
otherwise left alone. The full format is documented at
[agentskills.io](https://agentskills.io/specification).

### Installing one from elsewhere

Two paths, depending on where it's coming from. An agent holding the
`manage_skill` tool uses it for anything the marketplace can resolve: a name
in the bundled registry or a tap, or a [PepeHub](https://hub.pepe-agent.com)
reference (`@handle/name`, or its page URL), the same registry-aware install
`mix pepe skill install` does, with trust and provenance tracked the same way.
For a source with no registry entry at all (a bare URL, a gist, a one-off
repo), the `install-skill` skill teaches an agent to fetch it by hand instead.
Either way, skill text from outside is untrusted input: the agent
security-scans it with the `scan_skill` tool before writing it to disk. The
scan flags prompt injection, secret exfiltration, destructive commands,
persistence and obfuscation. It is a second check, not a substitute for
reading the content, and it never installs anything itself.

## Installing from a marketplace

`manage_skill` (above) is the conversational path for anything the registries/PepeHub can
resolve. `mix pepe skill` is the operator path to the exact same registries, with the same
search and update story:

```bash
pepe skill search release            # search every tap plus the bundled registry
pepe skill install cut-a-release     # install by name
pepe skill install @jhonathas/google-workspace   # or a PepeHub reference (see below)
pepe skill install cut-a-release --source https://example.com/cut-a-release.md   # or directly
pepe skill install read-pdf --source https://github.com/some-org/skills          # one skill out of a shared collection
pepe skill update cut-a-release      # re-fetch from the exact source it was installed from
pepe skill tap add https://github.com/your-team/pepe-skills   # add a registry beyond the bundled default
```

A name shaped `@handle/name` (or the package's own page URL, copied straight from
[PepeHub](https://hub.pepe-agent.com)) resolves against PepeHub itself, Pepe's plugin/skill
registry, instead of the bundled registry or a tap. It's checked first, since no bundled entry
or tap uses that shape. It's installed under the bare package slug (`google-workspace`, not
`@jhonathas/google-workspace`), the name every other skill command and the `skill` tool use.
Pointing `skill install` at a name that turns out to be a plugin on PepeHub, not a skill, fails
with a clear message telling you to use `plugin install` instead.

A source can hold a whole collection of skills side by side, each in its own folder,
which is how most public collections are published. Installing by name picks the
folder with that name, so `pepe skill install read-pdf --source <repo>` brings back
that one skill and its files, not whichever one the repository happened to list first.

Every install goes through the same static security scan `manage_skill`/`install-skill` use; a dangerous
verdict is refused unless you pass `--force`. Trust is `"official"` for the bundled, in-repo
registry (curated by Pepe's own maintainers) and for a PepeHub package PepeHub itself has
manually marked official. Anything resolved through a tap you added, an unmarked PepeHub
package, or installed with `--source`, is `"community"`: when an agent reads it with the
`skill` tool, its content is wrapped in the same untrusted-content marker a fetched web page
carries, until you've reviewed it yourself.

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
