Use when asked to create, edit, audit, tidy, or improve a skill.

A **skill** is a short Markdown file that teaches you (the agent) *how to use the
tools* to handle a recurring kind of request — when to act and exactly what to do.
Skills are how Cortex grows new know-how without new code.

## How skills work in Cortex (read this first)

- One skill = one Markdown file, named in `kebab-case`, e.g. `read-pdf.md`.
- It lives in your skills space: write it with `write_file` to `skills/<name>.md`
  (that resolves to `~/.cortex/skills/`). Built-in skills ship read-only; a user
  skill of the same name overrides one.
- **The first non-empty line is the summary.** Only the *name + that one line* are
  ever shown to you automatically (in your skills list). The full body is read **on
  demand** with the `skill` tool when its topic comes up.
- That's the whole economy: the summary must make it obvious *when* to open the
  skill; the body holds the *how*. Keep the body lean — every skill you read spends
  tokens, so include only what isn't obvious.

## When to make a skill (and when not to)

Make one when a request type **recurs** and the right way to handle it is **non-
obvious** — a specific sequence of tool calls, a saved script to run, an API quirk,
a house rule. Examples: "read a PDF", "post to our API", "triage the inbox".

Do **not** make a skill for one-offs, for things the model already does well
unaided, or for restating a tool's own description. If a request needs a *capability
you don't have*, that's a **tool**, not a skill — write a plugin (see the
`install-tool` skill); a skill only teaches how to *use* tools that exist.

## Anatomy of a great skill

1. **Trigger line (line 1).** Start with "Use when …" and name the situation in
   concrete terms the future-you will recognize. This is the most important line.
2. **Imperative and specific.** Write instructions to yourself: "Call `run_script`
   with `file: scripts/read-pdf.py` and the path as `args`." Name the exact tools,
   arguments, file paths, and order.
3. **Progressive disclosure.** Keep the main flow short. Push edge cases, long
   reference tables, or big examples to the end (or to a saved file you point to),
   so the common path stays cheap to read.
4. **Show the happy path, then gotchas.** One concrete example beats paragraphs.
   Then list the traps ("the API needs the token in a header", "deny loops").
5. **Prefer scripts for real work.** If the procedure involves computation/parsing,
   have the skill save and re-run a script (see the `write-a-script` skill) rather
   than doing it by hand each time.
6. **Lean.** Cut anything obvious or generic. Aim for a screenful, not an essay.

## Create a skill — procedure

1. **Check what exists.** List your skills; if a near-match exists, edit it instead
   of adding a duplicate. Read related ones to match style and avoid overlap.
2. **Pick a name.** `kebab-case`, descriptive, matching the trigger (`triage-inbox`).
3. **Draft** following the anatomy above. Confirm line 1 is a sharp "Use when …".
4. **Write it:** `write_file` to `skills/<name>.md`.
5. **Validate** (see checklist). Then it shows up in your skills list immediately —
   no restart — and you (or other agents) can open it with the `skill` tool.

## Edit / audit / tidy existing skills

- **Edit:** `read_file` it, improve in place, `write_file` back. Keep the trigger
  line intact unless you're deliberately re-scoping it.
- **Audit:** is the trigger accurate? Are tool names/arguments still correct? Any
  step that no longer matches reality? Remove stale or duplicated guidance.
- **Tidy:** merge overlapping skills, shorten bloat, move rarely-needed detail to
  the bottom. A leaner skill is read more cheaply and more often.

## Checklist before you finish

- [ ] Line 1 is a concrete "Use when …" trigger.
- [ ] Names real tools with exact arguments; steps are in order.
- [ ] Has at least one concrete example.
- [ ] No restating of tool descriptions; nothing obvious; no bloat.
- [ ] `kebab-case` filename; written to `skills/<name>.md`.
- [ ] Doesn't duplicate an existing skill (or it intentionally replaces one).
