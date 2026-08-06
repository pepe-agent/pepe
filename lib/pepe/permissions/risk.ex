defmodule Pepe.Permissions.Risk do
  @moduledoc """
  Lightweight, pattern-based **risk hints** for a tool call - a human-readable note
  of *what makes it risky*, shown next to the authorize prompt (e.g. "runs embedded
  code", "deletes files"). It's a cheap heuristic to help the user decide, not a
  full shell command-explainer/analyzer.

  Hint labels are translated via Gettext, so any surface (Telegram, the console)
  renders the same vocabulary in the user's language.
  """

  use Gettext, backend: Pepe.Gettext

  @type kind ::
          :inline_eval
          | :download_exec
          | :deletes
          | :elevated
          | :network
          | :writes_file
          | :changes_config
          | :reads_outside
          | :writes_outside
          | :writes_skill
          | :flagged_skill

  @doc "Risk hint kinds for a tool call, from its decoded args map."
  @spec hints(String.t(), map()) :: [kind()]
  def hints(name, args) when is_map(args) do
    Enum.uniq(tool_hints(name) ++ path_hints(name, args) ++ command_hints(command_text(name, args)))
  end

  def hints(_name, _args), do: []

  @doc "A translated, human-readable label for a risk kind."
  @spec label(kind()) :: String.t()
  def label(:inline_eval), do: gettext("runs embedded code")
  def label(:download_exec), do: gettext("downloads and runs code")
  def label(:deletes), do: gettext("deletes files")
  def label(:elevated), do: gettext("runs with elevated privileges")
  def label(:network), do: gettext("accesses the network")
  def label(:writes_file), do: gettext("writes to a file")
  def label(:changes_config), do: gettext("changes Pepe configuration")
  def label(:reads_outside), do: gettext("reads a file outside its workspace")
  def label(:writes_outside), do: gettext("writes outside its workspace")
  def label(:writes_skill), do: gettext("adds or changes a skill")
  def label(:flagged_skill), do: gettext("a skill whose content looks unsafe")

  # Risks that depend on WHERE a file tool points, not just which tool it is. A relative path
  # stays inside the agent's own workspace (and `shared/`) and is the free, always-safe read the
  # tools are meant to be. An absolute path, or one that climbs out with `..`, can reach another
  # tenant's files, `~/.pepe/config.json`, `~/.ssh`, `/etc` - so it carries a risk and stops
  # being always-safe, which routes it through the gate (refused where there is nobody to ask)
  # and the taint. Writing additionally treats `plugins/` and `skills/` as outside, because
  # `plugins/` is loaded as code, so a write there stays `:writes_outside` (injection, gated).
  # `skills/` is a legitimate learning target (the background review saves skills there), so it gets
  # its own `:writes_skill` risk - which the review's grant can cover precisely, WITHOUT also
  # granting code-dir or absolute-path writes. A skills write whose content trips the injection
  # scanner additionally flags `:flagged_skill` (see flagged_skill/1).
  defp path_hints("read_file", %{"path" => p}), do: reads_outside(p)
  defp path_hints("list_dir", %{"path" => p}), do: reads_outside(p)

  defp path_hints(name, %{"path" => p} = args) when name in ["write_file", "edit_file"],
    do: writes_outside(p, args)

  defp path_hints("move_file", %{"from" => from, "to" => to}),
    do: Enum.uniq(writes_outside(from) ++ writes_outside(to))

  defp path_hints(_name, _args), do: []

  defp reads_outside(p) when is_binary(p), do: if(climbs_out?(p), do: [:reads_outside], else: [])
  # A non-string path is never a legitimate in-workspace read. The model controls the tool
  # arguments, and a JSON array of char codes (`[47,101,...]`) decodes to a charlist that is a
  # valid path for `File.read/1` but skips the `is_binary` checks above - so treat any non-string
  # path as outside, forcing it through the gate instead of the always-safe short-circuit.
  defp reads_outside(_), do: [:reads_outside]

  # move_file carries no content to scan, so it passes an empty args map.
  defp writes_outside(p) when is_binary(p), do: writes_outside(p, %{})
  defp writes_outside(_p), do: [:writes_outside]

  defp writes_outside(p, args) when is_binary(p) do
    cond do
      # Absolute paths and `..` escapes win FIRST, so `skills/../config.json` and the absolute
      # spelling of the skills dir stay `:writes_outside`, never `:writes_skill`.
      climbs_out?(p) -> [:writes_outside]
      skill_path?(p) -> [:writes_skill | flagged_skill(args)]
      plugin_path?(p) -> [:writes_outside]
      true -> []
    end
  end

  defp writes_outside(_p, _args), do: [:writes_outside]

  # Absolute, or escaping the workspace with a `..` segment (checked on the split path so
  # `shared/../../etc` is caught regardless of its prefix).
  defp climbs_out?(p), do: Path.type(p) == :absolute or ".." in Path.split(p)

  defp skill_path?(p), do: match?(["skills" | _], Path.split(p))
  defp plugin_path?(p), do: match?(["plugins" | _], Path.split(p))

  # The extra risk a skills-dir write earns when its content trips the Sentinel injection scanner's
  # `:danger` verdict (prompt injection, credential exfiltration, persistence). The background
  # review's grant covers `:writes_skill` but NOT `:flagged_skill`, so a poisoned skill is refused
  # even with no human in the loop, while a clean skill saves silently. On a human surface it just
  # becomes one more line in the authorize prompt.
  defp flagged_skill(args) do
    text = Enum.map_join(["content", "new_string"], "\n", &to_string(args[&1] || ""))
    if Pepe.Skills.Sentinel.scan(text).verdict == :danger, do: [:flagged_skill], else: []
  end

  # The command/code string to scan, per tool.
  defp command_text("bash", %{"command" => c}) when is_binary(c), do: c
  defp command_text("run_script", %{"code" => c}) when is_binary(c), do: c
  defp command_text(_name, _args), do: ""

  # Risks implied by the tool itself, regardless of args.
  defp tool_hints(name) when name in ["write_file", "edit_file", "move_file"], do: [:writes_file]

  defp tool_hints("browser"), do: [:network]

  defp tool_hints(name) when name in ["config_set", "enable_tool", "set_route", "rename_agent"],
    do: [:changes_config]

  defp tool_hints(_name), do: []

  # Risks inferred from the command/code text.
  defp command_hints(""), do: []

  defp command_hints(text) do
    t = String.downcase(text)

    [
      {:inline_eval, inline_eval?(t)},
      # Not just `curl | sh`: anything piped into a shell OR scripting-language interpreter
      # (optionally by a full path, `/bin/sh`, `/usr/bin/env python3`), since a download tool
      # hidden behind a pipeline (`base64 -d payload | python3`, `curl ... | /bin/sh`) is the
      # same shape of risk without a `curl | sh` literal for the older, narrower pattern to catch.
      #
      # The lookahead after the interpreter name requires whitespace/`;`/`&`/`|`/end-of-string,
      # not `\b` alone: `\b` only checks the word BOUNDARY, so it happily matched the "sh" inside
      # an unrelated `grep -E "\.(md|txt|sh)$"` pattern too (`|sh)` - `)` is a non-word char, so
      # `\bsh\b` matched right there) - a real `| sh` invocation is never immediately followed by
      # a closing paren/quote, only by more shell syntax or the end of the command.
      {:download_exec, Regex.match?(~r/\|\s*(?:\S*\/)?(?:sh|bash|zsh|python3?|perl|ruby|node)(?=[\s;&|]|$)/, t)},
      # Any `rm`, not just one carrying a flag: `rm file.txt` deletes a file exactly as much as
      # `rm -f file.txt` does. `find ... -delete` and `dd` (overwriting a target) delete the
      # same way without the word "rm" anywhere in the command. `git clean -fd` deletes every
      # untracked file in the tree without the word "rm" either; `shred` is a delete that also
      # overwrites first, still a delete.
      {:deletes, Regex.match?(~r/\brm\b|\brmdir\b|\bunlink\b|-delete\b|\bdd\b|\bgit\s+clean\b|\bshred\b/, t)},
      {:elevated, Regex.match?(~r/\bsudo\b|\bdoas\b/, t)},
      # `(?<![.\w-])` before the interpreter name: without it, `\bssh\b` matched the "ssh" inside
      # a `~/.ssh` PATH (`cat ~/.ssh/config`, `ls ~/.ssh`), and `\bnc\b` matched the `-nc` flag
      # some tools take (word boundaries alone don't see path separators or hyphens as
      # "not part of the word" here the way plain English usage would suggest).
      {:network, Regex.match?(~r/(?<![.\w-])(curl|wget|nc|ssh|scp)\b/, t)},
      # Not just an absolute-path redirect or `tee`: a relative one (`> notes.txt`) writes a
      # file exactly as much as `> /tmp/notes.txt` does (excluding `>&1`-style fd duplication,
      # which writes nothing - `[^\s&]` already excludes it - and `> /dev/null`/`>/dev/null`,
      # the standard "discard this output" idiom: it opens the null device, not a real file,
      # and flagging it caught real users off guard - `2>/dev/null` on an otherwise risk-free
      # `find`/`grep`/`cat` pipeline is not a write anyone needs to be asked about). `mv`/`cp`
      # relocate or overwrite a file the same way; `chmod` turns whatever a prior step just
      # wrote into something that can run on its own later (a dropped git hook, a cron entry)
      # - the same shape of risk as the write itself. `sed -i` edits a file in place (the
      # `edit_file` tool's own equivalent always flags `:writes_file`, so this must too);
      # `truncate` zeroes a file's contents; `tar x...`/`unzip` write however many files an
      # archive says to, with names the archive controls.
      #
      # (?<![-=|]) before the redirect: without it, Elixir's own `->`, `=>`, `|>` operators
      # tripped this in every pipe/case/cond an agent's own bash grep'd for (verified live:
      # `grep -rn "->" lib` flagged "writes to a file" in this very project). `<` is
      # deliberately NOT in that set, unlike those three: bash has no `->`/`=>`/`|>` syntax
      # at all, so those sequences can only ever be literal argument text (a grep pattern,
      # say) - but `<>` is real, meaningful bash syntax (`3<>file.txt` opens a file for
      # read+write without truncating), so excluding it would silently stop flagging a
      # genuine file write instead of only ruling out an Elixir-source false positive.
      # (?>>{1,2}) is still an ATOMIC group: without it, `>>` can backtrack down to matching
      # just one `>`, leaving the second `>` to satisfy `[^\s&]` itself - which slips right
      # past the /dev/null lookahead below it (verified live: `>> /dev/null` wrongly matched
      # until this was atomic).
      {:writes_file,
       Regex.match?(
         ~r/(?<![-=|])(?>>{1,2})\s*(?!\/dev\/null\b)[^\s&]|\btee\b|\bmv\b|\bcp\b|\bchmod\b|\bsed\b[^|;&\n]*\s-i\b|\btruncate\b|\btar\b\s+-?\w*x|\bunzip\b/,
         t
       )}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # `python -c`, `node -e`, ... or a heredoc piped into a script interpreter.
  #
  # Between the interpreter and `-c`/`-e`, only more flags are allowed (`(?:\s+--?[\w-]+)*`),
  # not `[^\n]*` (anything): the old, permissive version matched `python -m pip install -e .`
  # (a routine dependency install) because "-e" appears ANYWHERE later in the line, regardless
  # of what came before it. `pip`/`install`/`.` aren't flag-shaped, so the loop stops there and
  # the mandatory `-c`/`-e` right after it never matches - while `python3 -u -c '...'` still
  # does, since `-u` IS flag-shaped and the loop's backtracking still finds `-c` right after.
  #
  # Also catches an obfuscated payload run without an interpreter flag at all: `eval`, `source`,
  # a piped `base64 -d`/`xxd -r` decode - none of these need `python -c` to execute code the
  # human never sees in the clear.
  #
  # `eval`/`source` are only actual invocations at command position - right after the start
  # of the string or a shell separator (`;`, `&&`, `||`, `|`, a newline, or `(`/backtick
  # opening a subshell), with only whitespace in between. Without that anchor, the bare
  # words matched anywhere on the line: `ls source/`, `find source -name "*.ex"`, a filename
  # or grep pattern containing "eval" - none of those run anything, but all got flagged.
  defp inline_eval?(t) do
    Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)(?:\s+--?[\w-]+)*\s+-[ce]\b/, t) or
      (String.contains?(t, "<<") and Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)\b/, t)) or
      Regex.match?(~r/(?:\A|[;&|\n(`])\s*\b(eval|source)\b/, t) or
      Regex.match?(~r/\bbase64\s+(-d|--decode)\b|\bxxd\s+-r\b/, t)
  end
end
