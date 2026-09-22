defmodule Pepe.Skills.Render do
  @moduledoc """
  What a skill's text becomes at the moment it is opened.

  The file on disk stays what the author wrote. When the `skill` tool opens it, four things
  are applied in this order, each one the operator's choice or plain information:

    1. **Template variables.** `${PEPE_SKILL_DIR}` (the skill's own directory, so a skill can
       say `${PEPE_SKILL_DIR}/scripts/run.sh` and mean the copy that is actually installed),
       `${PEPE_SKILLS_DIR}` and `${PEPE_SESSION_ID}`. Anything else in `${...}` is left alone.
       On by default; `skills.template_vars: false` turns it off.
    2. **Inline shell.** A `` !`command` `` snippet is replaced by the command's output. Off by
       default (`skills.inline_shell`). Each command goes through `Pepe.Permissions.gate/3`
       exactly as if the agent had called `bash` with it, so an unattended surface refuses
       anything not already approved. It never runs for a skill installed from a community
       source, only when the agent holds `bash`, at most #{10} distinct commands per load, and
       its output is capped.
    3. **Configuration.** Settings the skill declares under `metadata.pepe.config` are listed
       with the value the operator set (or the skill's default), so the skill's instructions
       can refer to them.
    4. **Readiness.** If the skill declares environment variables or commands that this
       machine lacks, a note is placed ahead of the text saying so (see
       `Pepe.Skills.Readiness`).

  `auto_loaded/1` is the other half: skills the operator listed under `skills.auto_load` are
  placed in the system prompt of every agent that can open skills. They render without inline
  shell (there is no one to ask while a prompt is being assembled) and never when the skill came
  from a community source, whose text must not reach the system prompt.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Readiness
  alias Pepe.Skills.Settings
  alias Pepe.Skills.Skill

  @inline ~r/!`([^`\n]+)`/
  @max_inline 10
  @max_output 2_000
  @auto_load_cap 6_000

  @doc """
  Render `content` (the text of `skill`) for the caller in `ctx`, the tool context of the turn
  (`:session_key`, `:agent`, `:authorize` and so on). Option `:inline_shell` is `false` to skip
  snippets regardless of the setting; `:env` and `:which` reach `Pepe.Skills.Readiness.check/2`.
  """
  @spec render(Skill.t(), String.t(), map(), keyword()) :: String.t()
  def render(%Skill{} = skill, content, ctx \\ %{}, opts \\ []) do
    body =
      content
      |> substitute(skill, ctx)
      |> inline_shell(skill, ctx, Keyword.get(opts, :inline_shell, true))
      |> append_config(skill)

    (skill |> Readiness.check(Keyword.take(opts, [:env, :which])) |> Readiness.setup_block() || "") <> body
  end

  @doc """
  `[{name, text}]` for the skills in `skills.auto_load` that this agent may carry in its
  system prompt. Options as for `Pepe.Skills.Catalog.visible/1`.
  """
  @spec auto_loaded(keyword()) :: [{String.t(), String.t()}]
  def auto_loaded(opts \\ []) do
    wanted = Settings.auto_load()

    if wanted == [] or not can_open?(opts[:agent]) do
      []
    else
      for %Skill{name: name} = skill <- Catalog.visible(opts),
          name in wanted,
          not community?(name),
          {:ok, content} <- [File.read(skill.entry)] do
        {name, skill |> render(content, %{}, inline_shell: false) |> cap(@auto_load_cap, name)}
      end
    end
  end

  @doc "Whether a skill was installed from a community source (an operator-added tap, or a direct URL)."
  @spec community?(String.t()) :: boolean()
  def community?(name) do
    match?(%{"trust_level" => "community"}, Pepe.Config.installed_skill(name))
  end

  # -- template variables ------------------------------------------------------------------

  defp substitute(content, skill, ctx) do
    if Settings.template_vars?() do
      Regex.replace(~r/\$\{(PEPE_[A-Z_]+)\}/, content, fn whole, var -> variable(var, skill, ctx) || whole end)
    else
      content
    end
  end

  defp variable("PEPE_SKILL_DIR", skill, _ctx), do: skill.dir || Path.dirname(skill.entry)
  defp variable("PEPE_SKILLS_DIR", _skill, _ctx), do: Skills.user_dir()
  defp variable("PEPE_SESSION_ID", _skill, %{session_key: key}) when is_binary(key), do: key
  defp variable(_var, _skill, _ctx), do: nil

  # -- inline shell ------------------------------------------------------------------------

  defp inline_shell(content, skill, ctx, allowed?) do
    if allowed? and Settings.inline_shell?() and not community?(skill.name) do
      commands = @inline |> Regex.scan(content, capture: :all_but_first) |> List.flatten() |> Enum.uniq()
      {run, skipped} = Enum.split(commands, @max_inline)

      results =
        Map.new(run, &{&1, run_inline(&1, ctx)}) |> Map.merge(Map.new(skipped, &{&1, "[inline command not run: too many in one skill]"}))

      Regex.replace(@inline, content, fn _whole, command -> Map.fetch!(results, command) end)
    else
      content
    end
  end

  defp run_inline(command, ctx) do
    if holds_bash?(ctx[:agent]), do: gated_run(%{"command" => command}, ctx), else: "[inline command not run: this agent has no bash tool]"
  end

  defp gated_run(args, ctx) do
    case Pepe.Permissions.gate("bash", args, Map.put(ctx, :no_pending_approval, true)) do
      :allow ->
        %{"function" => %{"name" => "bash", "arguments" => args}}
        |> Pepe.Tools.execute(ctx)
        |> command_output()
        |> cap(@max_output, "inline command")

      :deny ->
        "[inline command not run: not authorized]"

      {:deny, reason} ->
        "[inline command not run: #{reason}]"
    end
  end

  # The bash tool answers `exit_status=N` and then the output. A snippet wants the output; a
  # failing command keeps its status so the skill's reader can tell it did not work.
  defp command_output("exit_status=0\n" <> output), do: String.trim(output)

  defp command_output("exit_status=" <> rest) do
    case String.split(rest, "\n", parts: 2) do
      [status, output] -> "[command exited with status #{status}] " <> String.trim(output)
      _ -> String.trim(rest)
    end
  end

  defp command_output(other), do: String.trim(other)

  defp holds_bash?(%{tools: tools}) when is_list(tools), do: "bash" in tools
  defp holds_bash?(_agent), do: true

  # -- configuration -----------------------------------------------------------------------

  defp append_config(content, %Skill{fields: %{config_vars: []}}), do: content

  defp append_config(content, %Skill{fields: %{config_vars: vars}}) do
    values = Settings.config_values()

    lines =
      Enum.map(vars, fn var ->
        "- #{var.key}: #{show(Map.get(values, var.key, var.default))} (#{var.description})"
      end)

    content <> "\n\n## Skill configuration (set by the operator)\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp show(nil), do: "not set"
  defp show(""), do: "not set"
  defp show(value) when is_binary(value), do: value
  defp show(value) when is_list(value), do: Enum.map_join(value, ", ", &show/1)
  defp show(value), do: inspect(value)

  # -- helpers -----------------------------------------------------------------------------

  defp can_open?(%{tools: tools}) when is_list(tools), do: "skill" in tools
  defp can_open?(_agent), do: true

  defp cap(text, limit, what) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n[#{what} truncated at #{limit} characters]",
      else: text
  end
end
