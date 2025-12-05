defmodule Cortex.Skills do
  @moduledoc """
  Skills are on-demand instruction docs (Markdown) that teach the agent a
  *procedure* — e.g. how to install a tool. Built-in skills ship under
  `priv/skills/`; user skills live in `<CORTEX_HOME>/skills/` and override a
  built-in of the same name.

  They are NOT loaded into the system prompt in full — only their name + a one-line
  summary are listed there. The agent reads the relevant one with the `skill` tool
  when its topic comes up, keeping context lean.
  """

  alias Cortex.Config

  @doc "User skills directory."
  def user_dir, do: Path.join(Config.home(), "skills")

  defp builtin_dir, do: Application.app_dir(:cortex, "priv/skills")

  @doc "All skills as `[{name, summary}]` (user skills override built-ins by name)."
  def list do
    (skills_in(builtin_dir()) ++ skills_in(user_dir()))
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Read a skill's full Markdown by name (user dir wins over built-in)."
  def read(name) do
    user = Path.join(user_dir(), name <> ".md")
    builtin = Path.join(builtin_dir(), name <> ".md")

    cond do
      File.regular?(user) -> File.read(user)
      File.regular?(builtin) -> File.read(builtin)
      true -> {:error, :not_found}
    end
  end

  defp skills_in(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          {String.replace_suffix(file, ".md", ""), summary(Path.join(dir, file))}
        end)

      _ ->
        []
    end
  end

  # The first non-empty line is the skill's "use-when" summary.
  defp summary(path) do
    with {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           content |> String.split("\n") |> Enum.find(&(String.trim(&1) != "")) do
      line |> String.replace_prefix("# ", "") |> String.trim() |> String.slice(0, 120)
    else
      _ -> ""
    end
  end
end
