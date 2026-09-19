defmodule Pepe.Skills.Settings do
  @moduledoc """
  The operator's skill settings, all under `"skills"` in `config.json` next to the
  existing `"taps"` and `"installed"` keys:

    * `disabled` - skill names switched off everywhere.
    * `channel_disabled` - `%{"telegram" => [names]}`: switched off on one channel only
      (a channel is the first segment of a session key: `telegram`, `web`, `tui`, `acp`,
      `whatsapp`, ...). A skill disabled globally stays disabled on every channel.
    * `external_dirs` - extra directories of skills, read in place, never written to.
    * `trusted_project_dirs` - repositories whose own `.pepe/skills` and `.agents/skills`
      may load (see `Pepe.Skills.Project`).
    * `auto_load` - skills whose full text is placed in the system prompt of every agent
      that holds the `skill` tool, instead of waiting to be read.
    * `template_vars` - substitute `${PEPE_SKILL_DIR}` and friends when a skill loads
      (on by default).
    * `inline_shell` - run `!`command`` snippets in a skill when it loads, each through
      the permission gate (off by default).
    * `config` - values for the settings a skill declares under `metadata.pepe.config`.
  """

  alias Pepe.Config

  defp section do
    case Config.load()["skills"] do
      %{} = map -> map
      _ -> %{}
    end
  end

  @doc "Skill names disabled everywhere."
  @spec disabled() :: [String.t()]
  def disabled, do: names(section()["disabled"])

  @doc "Skill names disabled on `channel` (globally disabled names excluded - see `disabled/0`)."
  @spec channel_disabled(String.t() | nil) :: [String.t()]
  def channel_disabled(nil), do: []

  def channel_disabled(channel) do
    case section()["channel_disabled"] do
      %{} = map -> names(map[to_string(channel)])
      _ -> []
    end
  end

  @doc "Every name disabled on `channel`: the global list plus that channel's own."
  @spec disabled_on(String.t() | nil) :: MapSet.t(String.t())
  def disabled_on(channel), do: MapSet.new(disabled() ++ channel_disabled(channel))

  @doc "Extra skill directories that exist on disk."
  @spec external_dirs() :: [String.t()]
  def external_dirs do
    section()["external_dirs"]
    |> names()
    |> Enum.map(&expand/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Pepe.Skills.user_dir()))
    |> Enum.filter(&File.dir?/1)
  end

  @doc "Configured external directories as written, existing or not."
  @spec external_dirs_configured() :: [String.t()]
  def external_dirs_configured, do: names(section()["external_dirs"])

  @doc "Repository roots whose project skills are trusted."
  @spec trusted_project_dirs() :: [String.t()]
  def trusted_project_dirs, do: section()["trusted_project_dirs"] |> names() |> Enum.map(&expand/1)

  @doc "Names of the auto-loaded skills."
  @spec auto_load() :: [String.t()]
  def auto_load, do: names(section()["auto_load"])

  @doc "Whether `${PEPE_SKILL_DIR}`-style tokens are substituted (default true)."
  @spec template_vars?() :: boolean()
  def template_vars?, do: section()["template_vars"] != false

  @doc "Whether inline `!`cmd`` snippets run when a skill loads (default false)."
  @spec inline_shell?() :: boolean()
  def inline_shell?, do: section()["inline_shell"] == true

  @doc "Values set for skill-declared settings."
  @spec config_values() :: %{String.t() => term()}
  def config_values do
    case section()["config"] do
      %{} = map -> map
      _ -> %{}
    end
  end

  # -- writers ----------------------------------------------------------------------------

  @doc "Disable `name` everywhere, or only on `channel`."
  @spec disable(String.t(), String.t() | nil) :: :ok
  def disable(name, nil), do: put_list("disabled", &Enum.uniq(&1 ++ [name]))

  def disable(name, channel) do
    update(fn skills ->
      Map.update(skills, "channel_disabled", %{channel => [name]}, fn map ->
        Map.update(map, channel, [name], &Enum.uniq(&1 ++ [name]))
      end)
    end)
  end

  @doc "Undo `disable/2`."
  @spec enable(String.t(), String.t() | nil) :: :ok
  def enable(name, nil), do: put_list("disabled", &List.delete(&1, name))

  def enable(name, channel) do
    update(fn skills ->
      Map.update(skills, "channel_disabled", %{}, fn map ->
        Map.update(map, channel, [], &List.delete(&1, name))
      end)
    end)
  end

  @spec add_external_dir(String.t()) :: :ok
  def add_external_dir(dir), do: put_list("external_dirs", &Enum.uniq(&1 ++ [dir]))

  @spec remove_external_dir(String.t()) :: :ok
  def remove_external_dir(dir), do: put_list("external_dirs", &List.delete(&1, dir))

  @spec trust_project(String.t()) :: :ok
  def trust_project(root), do: put_list("trusted_project_dirs", &Enum.uniq(&1 ++ [root]))

  @spec untrust_project(String.t()) :: :ok
  def untrust_project(root), do: put_list("trusted_project_dirs", &List.delete(&1, root))

  @spec add_auto_load(String.t()) :: :ok
  def add_auto_load(name), do: put_list("auto_load", &Enum.uniq(&1 ++ [name]))

  @spec remove_auto_load(String.t()) :: :ok
  def remove_auto_load(name), do: put_list("auto_load", &List.delete(&1, name))

  @spec set_flag(String.t(), boolean()) :: :ok
  def set_flag(key, value) when key in ["template_vars", "inline_shell"] and is_boolean(value) do
    update(&Map.put(&1, key, value))
  end

  @spec put_config(String.t(), term()) :: :ok
  def put_config(key, value), do: update(fn skills -> Map.update(skills, "config", %{key => value}, &Map.put(&1, key, value)) end)

  # -- internals ---------------------------------------------------------------------------

  defp put_list(key, fun) do
    update(fn skills -> Map.put(skills, key, skills |> Map.get(key) |> names() |> fun.()) end)
  end

  defp update(fun) do
    Config.update(fn config -> Map.update(config, "skills", fun.(%{}), fun) end)
    :ok
  end

  defp names(list) when is_list(list), do: list |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp names(value) when is_binary(value), do: names([value])
  defp names(_other), do: []

  defp expand(path), do: path |> Path.expand() |> String.trim_trailing("/")
end
