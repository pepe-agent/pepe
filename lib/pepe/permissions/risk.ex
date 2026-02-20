defmodule Pepe.Permissions.Risk do
  @moduledoc """
  Lightweight, pattern-based **risk hints** for a tool call — a human-readable note
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

  @doc "Risk hint kinds for a tool call, from its decoded args map."
  @spec hints(String.t(), map()) :: [kind()]
  def hints(name, args) when is_map(args) do
    Enum.uniq(tool_hints(name) ++ command_hints(command_text(name, args)))
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

  # `python -c`, `node -e`, … or a heredoc piped into a script interpreter.
  defp inline_eval?(t) do
    Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)\b[^\n]*\s-(c|e)\b/, t) or
      (String.contains?(t, "<<") and Regex.match?(~r/\b(python3?|node|ruby|perl|deno|php)\b/, t))
  end
end
