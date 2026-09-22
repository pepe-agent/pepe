defmodule Pepe.Skills.Commands do
  @moduledoc """
  Skills as slash commands, for every surface that has slash commands (Telegram, the console,
  the dashboard chat, an editor over ACP).

  A skill command is not a second way to run a skill. `/deploy staging` becomes an ordinary
  turn that tells the agent to carry out the `deploy` skill with `staging` as its input, and
  the agent reads it through its own `skill` tool like any other time. That is deliberate:
  the skill's text arrives as a tool result, where it is marked as untrusted when it came
  from a community source, instead of being pasted into the person's own message with the
  authority of something they typed. It also means the same visibility rules apply as
  everywhere else, because the commands offered are exactly `Pepe.Skills.Catalog.visible/1`.

  What is offered is narrower than what exists:

    * an agent without the `skill` tool is offered none (it could not open them);
    * disabled skills, skills for another operating system or channel, and skills that need a
      tool the agent does not hold are absent, as in the skills index;
    * a name that collides with a built-in command is not offered as its own command (the
      built-in wins) and is reached as `/skill <name>` on the surfaces that have that.

  Who may run a command is each surface's own rule, not decided here.
  """

  alias Pepe.Config
  alias Pepe.Skills.Catalog
  alias Pepe.Skills.Readiness

  @max_command 32

  @type entry :: %{name: String.t(), command: String.t(), summary: String.t(), needs: String.t() | nil}

  @type opts :: [agent: String.t() | map() | nil, channel: String.t() | nil, cwd: String.t() | nil, reserved: [String.t()]]

  @doc """
  The commands this caller is offered. `:agent` is an agent name or the agent itself,
  `:channel` the surface (`"telegram"`, `"tui"`, `"web"`, `"acp"`), `:reserved` the built-in
  command names a skill must not shadow.
  """
  @spec list(opts()) :: [entry()]
  def list(opts \\ []) do
    agent = resolve_agent(opts[:agent])

    if can_open?(agent) do
      reserved = MapSet.new(opts[:reserved] || [])

      [agent: agent, channel: opts[:channel], cwd: opts[:cwd]]
      |> Catalog.visible()
      |> Enum.map(&entry/1)
      |> Enum.reject(&(&1.command == "" or MapSet.member?(reserved, &1.command)))
      |> Enum.uniq_by(& &1.command)
    else
      []
    end
  end

  @doc """
  The skill a typed word refers to, or `:none`. The word may carry its leading slash and may be
  the skill's name, its `category/name` path, or the command form of either (Telegram cannot
  spell a hyphen, so `read-pdf` is also `read_pdf`).
  """
  @spec find(String.t(), opts()) :: {:ok, entry()} | :none
  def find(word, opts \\ []) when is_binary(word) do
    word = word |> String.trim() |> String.trim_leading("/")
    form = command_form(word)

    case Enum.find(list(Keyword.delete(opts, :reserved)), &(&1.name == word or &1.command == form)) do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  @doc """
  The turn a skill command runs: an instruction to the agent to carry the skill out, with
  the person's own words as its input. Model-facing, so always English.
  """
  @spec instruction(String.t(), String.t()) :: String.t()
  def instruction(name, args) do
    input = if String.trim(args) == "", do: "", else: "\n\nInput: " <> String.trim(args)
    "Carry out the \"#{name}\" skill now." <> input
  end

  @doc """
  The command spelling of a skill name: lowercase letters, digits and underscore, at most 32
  characters - the charset every chat surface accepts, Telegram's being the narrowest.
  """
  @spec command_form(String.t()) :: String.t()
  def command_form(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, @max_command)
  end

  defp entry(skill) do
    %{
      name: skill.name,
      command: command_form(skill.name),
      summary: skill.summary,
      needs: skill |> Readiness.check() |> Readiness.note()
    }
  end

  defp resolve_agent(name) when is_binary(name), do: Config.get_agent(name)
  defp resolve_agent(agent), do: agent

  # An agent whose tool list is known and lacks `skill` cannot open a skill, so offering the
  # command would only lead to a refusal. Anything else (no agent, unknown tools) is not gated.
  defp can_open?(%{tools: tools}) when is_list(tools), do: "skill" in tools
  defp can_open?(_agent), do: true
end
