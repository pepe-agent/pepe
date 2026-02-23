How to tackle a complex or multi-step task: write a script and run it.

When a request involves real computation, several steps, parsing/transforming data,
calling APIs, or anything fiddly, don't try to do it by hand turn-by-turn - write a
small program and run it with the `run_script` tool.

1. Pick a language:
   - `python` - great default for data, math, and APIs (usually installed).
   - `elixir` - always available here (it's the host runtime); good when Python isn't.
   - `node`, `ruby`, `bash` - when they fit better or are what's installed.
   If unsure whether an interpreter exists, just try; `run_script` tells you if it's
   missing, and you can switch language.
2. Write the FULL program (not a snippet). Print the result you need to stdout.
3. Call `run_script` with the language and code. You get back stdout+stderr and the
   exit code.
4. If it errored, read the output, fix the code, and run again. Iterate until it works.

Reuse and remember (do this for recurring demands, e.g. "read this PDF", "analyze
this spreadsheet"):
- If a script is worth keeping, save it with `write_file` under `scripts/` in your
  workspace (e.g. `scripts/read-pdf.py`). Re-run it later with
  `run_script` passing `file: "scripts/read-pdf.py"` and `args` - no need to rewrite it.
- When you've worked out HOW to do a recurring task, write a short skill documenting
  the steps: `write_file` a Markdown file to `skills/<name>.md`. Make the FIRST line a
  one-line "use when ..." summary; the rest is the procedure (which script to run, what
  args, gotchas). It then shows up in your skills list and you (or other agents) can
  read it next time with the `skill` tool.
- Missing a Python library? Install it first (e.g. `pip install pypdf openpyxl`) via
  `bash` or a small `run_script`, then proceed.

Tips:
- Scripts run in your workspace directory, so files they create live with you.
- Keep output focused - print just what you need (the tool truncates very long output).
- Don't ask the user to run anything; you run it yourself with `run_script`.
- For one-off shell commands, the `bash` tool is fine; reach for `run_script` when
  there's actual logic.
