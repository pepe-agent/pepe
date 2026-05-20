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

  # Risks that depend on WHERE a file tool points, not just which tool it is. A relative path
  # stays inside the agent's own workspace (and `shared/`) and is the free, always-safe read the
  # tools are meant to be. An absolute path, or one that climbs out with `..`, can reach another
  # tenant's files, `~/.pepe/config.json`, `~/.ssh`, `/etc` - so it carries a risk and stops
  # being always-safe, which routes it through the gate (refused where there is nobody to ask)
  # and the taint. Writing additionally treats `plugins/` and `skills/` as outside, because
  # those directories are loaded as code and procedures: a write there is injection, not data.
  defp path_hints("read_file", %{"path" => p}), do: reads_outside(p)
  defp path_hints("list_dir", %{"path" => p}), do: reads_outside(p)

  defp path_hints(name, %{"path" => p}) when name in ["write_file", "edit_file"],
    do: writes_outside(p)

  defp path_hints("move_file", %{"from" => from, "to" => to}),
    do: Enum.uniq(writes_outside(from) ++ writes_outside(to))

  defp path_hints(_name, _args), do: []

  defp reads_outside(p) when is_binary(p), do: if(climbs_out?(p), do: [:reads_outside], else: [])
  # A non-string path is never a legitimate in-workspace read. The model controls the tool
  # arguments, and a JSON array of char codes (`[47,101,...]`) decodes to a charlist that is a
  # valid path for `File.read/1` but skips the `is_binary` checks above - so treat any non-string
  # path as outside, forcing it through the gate instead of the always-safe short-circuit.
  defp reads_outside(_), do: [:reads_outside]

  defp writes_outside(p) when is_binary(p),
    do: if(climbs_out?(p) or into_code_dir?(p), do: [:writes_outside], else: [])

  defp writes_outside(_), do: [:writes_outside]

  # Absolute, or escaping the workspace with a `..` segment (checked on the split path so
  # `shared/../../etc` is caught regardless of its prefix).
  defp climbs_out?(p), do: Path.type(p) == :absolute or ".." in Path.split(p)

  # The plugins/ and skills/ dirs are compiled/loaded, so a write there is code, not data.
  defp into_code_dir?(p) do
    case Path.split(p) do
      ["plugins" | _] -> true
      ["skills" | _] -> true
      _ -> false
    end
  end

  # The command/code string to scan, per tool.
  defp command_text("bash", %{"command" => c}) when is_binary(c), do: c
  defp command_text("run_script", %{"code" => c}) when is_binary(c), do: c
  defp command_text(_name, _args), do: ""

  # Risks implied by the tool itself, regardless of args.
  defp tool_hints(name) when name in ["write_file", "edit_file", "move_file"], do: [:writes_file]

  defp tool_hints(name) when name in ["config_set", "enable_tool", "set_route", "rename_agent"],
    do: [:changes_config]

  defp tool_hints(_name), do: []

  # Risks inferred from the command/code text.
  defp command_hints(""), do: []

  defp command_hints(text) do
    t = String.downcase(text)

    [
      {:inline_eval, inline_eval?(t)},
      {:download_exec, Regex.match?(~r/(curl|wget)[^|]*\|\s*(sh|bash|zsh)/, t)},
      {:deletes, Regex.match?(~r/\brm\s+-|\brmdir\b|\bunlink\b/, t)},
      {:elevated, Regex.match?(~r/\bsudo\b|\bdoas\b/, t)},
      {:network, Regex.match?(~r/\b(curl|wget|nc|ssh|scp)\b/, t)},
      {:writes_file, Regex.match?(~r/>\s*\/|\btee\b/, t)}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # `python -c`, `node -e`, ... or a heredoc piped into a script interpreter.
  defp inline_eval?(t) do
    Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)\b[^\n]*\s-(c|e)\b/, t) or
      (String.contains?(t, "<<") and Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)\b/, t))
  end
end
