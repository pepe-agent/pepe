defmodule Pepe.Skills.Readiness do
  @moduledoc """
  Whether the machine a skill will run on has what the skill says it needs.

  A skill can declare environment variables (`required_environment_variables`, or the
  `setup.collect_secrets` and `prerequisites.env_vars` spellings the wider ecosystem uses)
  and commands (`required_commands`). Nothing about a missing one hides the skill: the
  instructions are still worth reading, and a person may be about to set the variable. What
  changes is that everyone who is about to rely on the skill is told, in the skills index,
  when it is opened and in `mix pepe skill list`, instead of finding out from the first
  command that fails halfway through a task.

  Variables marked `optional` never count as missing. A variable counts as present when it is
  set to something other than an empty string.
  """

  alias Pepe.Security.ExternalContent
  alias Pepe.Skills.Skill

  @type env_entry :: %{name: String.t(), help: String.t() | nil, optional: boolean(), required_for: String.t() | nil}

  @type t :: %{missing_env: [env_entry()], missing_commands: [String.t()], ready?: boolean()}

  @doc """
  What `skill` still needs. Options `:env` (a 1-arity variable lookup) and `:which` (a 1-arity
  executable lookup) exist so a test does not depend on the machine it runs on.
  """
  @spec check(Skill.t(), keyword()) :: t()
  def check(%Skill{fields: fields}, opts \\ []) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    which = Keyword.get(opts, :which, &System.find_executable/1)

    missing_env = for entry <- fields.required_env, not entry.optional, blank?(env.(entry.name)), do: entry
    missing_commands = for command <- fields.required_commands, is_nil(which.(command)), do: command

    %{missing_env: missing_env, missing_commands: missing_commands, ready?: missing_env == [] and missing_commands == []}
  end

  @doc "One short line for an index or a listing (`needs API_KEY, command jq`), or `nil` when ready."
  @spec note(t()) :: String.t() | nil
  def note(%{ready?: true}), do: nil

  def note(%{missing_env: env, missing_commands: commands}) do
    parts = Enum.map(env, & &1.name) ++ Enum.map(commands, &"command #{&1}")
    "needs " <> Enum.join(parts, ", ")
  end

  @doc """
  A paragraph to put ahead of a skill's text when it is opened and not ready: what is missing,
  and the help text the skill gave for each variable.
  """
  @spec setup_block(t()) :: String.t() | nil
  def setup_block(%{ready?: true}), do: nil

  def setup_block(%{missing_env: env, missing_commands: commands}) do
    lines =
      Enum.map(env, fn entry ->
        base = "- environment variable #{entry.name} is not set"
        base = if entry.required_for, do: base <> " (needed for #{clean(entry.required_for)})", else: base
        if entry.help, do: base <> ". #{clean(entry.help)}", else: base
      end) ++ Enum.map(commands, &"- command `#{&1}` is not installed")

    "<system-reminder>\nThis skill needs setup that is not done on this machine yet:\n" <>
      Enum.join(lines, "\n") <>
      "\nSay so before relying on the parts of the skill that use them; do not invent a value.\n</system-reminder>\n\n"
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  # `help`/`required_for` are free text from a skill's own frontmatter, which for a
  # community skill is exactly as trusted as a fetched web page - and this text is about
  # to be wrapped in the same `<system-reminder>` framing every genuinely-Pepe note uses.
  # `ExternalContent.strip_framing/1` is what keeps a forged `</system-reminder>` from
  # closing the real block early; newlines are also collapsed here so a multi-line value
  # cannot forge extra list lines or a second block of its own.
  defp clean(text) do
    text
    |> ExternalContent.strip_framing()
    |> String.replace(~r/\s*\n+\s*/, " ")
    |> String.trim()
  end
end
