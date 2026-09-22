defmodule Pepe.Skills.Ownership do
  @moduledoc """
  Who a skill belongs to, and therefore who may change it.

  A skill's *origin* is worked out from where it lives and what is recorded about it,
  never from its content or from how relevant anything thinks it is:

    * `:bundled` - ships with Pepe (`priv/skills/`). Read-only; a user skill of the same
      name overrides it, which is then a `:user` skill.
    * `:installed` - came from a registry, tap or URL (`pepe skill install`). Its source
      owns it; an update replaces whatever was edited locally.
    * `:agent` - the background review or the curator wrote it through `skill_manage` with
      nobody present, or a person handed it over with `pepe skill adopt`. The only origin the
      background review and the curator may change on their own. A skill an agent wrote in a
      conversation, with the person in front of it, is that person's (`:user`): they saw and
      allowed it, and nothing runs behind their back to rewrite it.
    * `:user` - anything else in the user skills directory: written by hand, or written
      before ownership was recorded. A skill nobody declared to be an agent's stays a
      person's, which is the safe default for the files most likely to matter to them.
    * `:missing` - no such skill.

  `pinned` is separate from origin: a pinned skill is off-limits to anything running
  without a person present, whatever its origin.

  ## Background versus foreground

  A *foreground* change is one a person is present for: an agent calling `skill_manage`
  in a conversation, where `Pepe.Permissions` puts the call in front of them (or a grant
  they gave earlier covers it). A *background* change is the review or the curator acting
  alone. `background_writable?/1` is the rule the latter is held to, and it is deliberately
  narrow: managed, agent-created, not pinned.
  """

  alias Pepe.Config
  alias Pepe.Skills
  alias Pepe.Skills.Stats

  @type origin :: :bundled | :installed | :agent | :user | :missing

  @name_format ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @doc "Is `name` a legal skill name: lowercase letters, digits, hyphens and underscores, 64 characters at most."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_format, name)
  def valid_name?(_), do: false

  @doc "The origin of the skill called `name`."
  @spec origin(String.t()) :: origin()
  def origin(name) when is_binary(name) do
    cond do
      not valid_name?(name) -> :missing
      user_entry(name) != nil -> user_origin(name)
      bundled?(name) -> :bundled
      true -> :missing
    end
  end

  defp user_origin(name) do
    cond do
      Config.installed_skill(name) != nil -> :installed
      match?(%{managed: true}, Stats.get(name)) -> :agent
      true -> :user
    end
  end

  @doc "Is the skill pinned?"
  @spec pinned?(String.t()) :: boolean()
  def pinned?(name), do: match?(%{pinned: true}, Stats.get(name))

  @doc """
  May the review or the curator change this skill with no person present? Only a managed,
  agent-created skill that nobody pinned.
  """
  @spec background_writable?(String.t()) :: boolean()
  def background_writable?(name), do: origin(name) == :agent and not pinned?(name)

  @doc "Where the user copy of `name` lives: `{:loose, file}`, `{:package, dir}`, or `nil`. A loose file wins, as it does for reading."
  @spec user_entry(String.t()) :: {:loose, String.t()} | {:package, String.t()} | nil
  def user_entry(name) do
    if valid_name?(name) do
      loose = Path.join(Skills.user_dir(), name <> ".md")
      package = Path.join(Skills.user_dir(), name)

      cond do
        File.regular?(loose) -> {:loose, loose}
        File.dir?(package) and Skills.package_entry(package) != nil -> {:package, package}
        true -> nil
      end
    end
  end

  @doc "The entry doc file of the user copy of `name`, or `nil`."
  @spec user_doc(String.t()) :: String.t() | nil
  def user_doc(name) do
    case user_entry(name) do
      {:loose, file} -> file
      {:package, dir} -> Skills.package_entry(dir)
      nil -> nil
    end
  end

  @doc "Does Pepe ship a skill called `name`?"
  @spec bundled?(String.t()) :: boolean()
  def bundled?(name) do
    valid_name?(name) and
      (File.regular?(Path.join(builtin_dir(), name <> ".md")) or
         (File.dir?(Path.join(builtin_dir(), name)) and Skills.package_entry(Path.join(builtin_dir(), name)) != nil))
  end

  @doc "A short reason a background actor may not change `name`, or `:ok`."
  @spec background_check(String.t()) :: :ok | {:refused, String.t()}
  def background_check(name) do
    case {origin(name), pinned?(name)} do
      {:agent, false} ->
        :ok

      {:agent, true} ->
        {:refused, "'#{name}' is pinned: only a person, in a conversation with them present, may change it."}

      {:bundled, _} ->
        {:refused, "'#{name}' ships with Pepe and is read-only here."}

      {:installed, _} ->
        {:refused, "'#{name}' was installed from a source that owns it; a background pass never edits it."}

      {:user, _} ->
        {:refused,
         "'#{name}' is a person's own skill, so it is not yours to change on your own - say in your reply what is wrong with it, and suggest they run `pepe skill adopt #{name}` if they want it maintained for them."}

      {:missing, _} ->
        {:refused, "no skill named '#{name}'."}
    end
  end

  defp builtin_dir, do: Application.app_dir(:pepe, "priv/skills")
end
