# Skills

Skills are on-demand instruction docs (Markdown) that teach an agent a *procedure*
- e.g. how to install a tool. They are listed (name + one-line summary) in the
agent's context, and the agent reads the relevant one with the `skill` tool when
its topic comes up, so they don't bloat every prompt.

- **Built-in** skills ship under `priv/skills/*.md`:
  - `skill-creator` - how to create, edit, audit and improve skills (the meta-skill).
  - `install-tool` - write a plugin tool and enable it from chat.
  - `write-a-script` - solve complex tasks by writing/saving a program to run.
  - `manage-routing` - change agent-to-agent routes with `set_route`.
  - `handle-media` - understand a voice/audio/image/file (transcribe, read), installing
    what it needs.
  - `install-skill` - install a skill from a URL, a gist, a repo, or another Pepe.
  - `create-watch` - set up a durable "check X and notify me when it happens" watch.

- **User** skills live in `~/.pepe/skills/*.md` and override a built-in of the
  same name. The first non-empty line is the summary; the rest is the procedure.

An agent can **author its own skills**: ask it to "remember how to do X as a skill"
and (guided by `skill-creator`) it writes a new `skills/<name>.md`, which then
appears in its skills list, no restart.

Combined with plugins + `enable_tool`, an agent can be asked in chat to "install a
tool that does X": it reads the `install-tool` skill, writes the plugin to
`plugins/<name>.exs`, enables it on itself, and uses it, with no restart.

For complex/multi-step work the agent doesn't grind it out by hand. The
`run_script` tool lets it write a short program (Python, Node, Ruby, Bash, or
Elixir, which is always available) and run it, getting back stdout/stderr/exit
code and iterating on errors. Worthwhile scripts are **saved** under `scripts/` and
re-run later (`run_script` with `file:`), and when the agent works out *how* to do
a recurring task (read a PDF, crunch a spreadsheet) it **writes itself a skill** to
`skills/<name>.md`. The `write-a-script` skill teaches the whole loop.

---

[Back to the docs index](../README.md#documentation)
