# Learning (self-improvement + TimeLearn)

An agent can **turn conversations into lasting knowledge on its own** - the
"reflect" loop. It learns only from **trusted conversations** so a client's chat
never becomes memory. Who counts as trusted is a per-bot `trainers` allowlist:

- **`["*"]`** -> learns from everyone

- **`[]`** -> learns from no one (a client-facing bot)

- **`[id1, id2]`** -> learns only from those user ids (your ids - the trainers)

- **omitted / `null`** -> the default (everyone)

The allowlist convention is the same everywhere in Pepe: `["*"]` = all, `[]` =
none, `[items]` = exactly those, and omitted/`null` = that field's default.

```bash
mix pepe gateway telegram add support --token $T --agent helper --trainers none
# a client-facing bot that never learns; your own DM bot (no --trainers) still does
```

After a trusted session the agent **reviews the conversation** and updates two
things, kept separate:

- **Memory** (about *you*) -> `USER.md` / `MEMORY.md` / `people.md`, kept lean
  (it consolidates instead of piling on).

- **Skills** (about *technique*) -> prefers updating a rich existing skill over
  spawning a narrow new one.

The review is a background run with tools restricted to file/skill management (no
shell/network), so it can update the workspace but nothing else; the live session
is untouched. It fires on `/compact`, on idle (~90s after the last turn), and on
demand with **`/learn`** (Telegram + console).

**TimeLearn** shows what an agent has learned, on a timeline - skills (🧠) and
memory entries (📝), newest first, with source and date:

```bash
mix pepe timelearn zak               # in the terminal
```

...or the **Learn** tab in the web dashboard (with an agent picker). The generator
(reflect) produces; TimeLearn displays.

---

[Back to the docs index](../README.md#documentation)
