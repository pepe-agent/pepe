defmodule Pepe.Docs do
  @moduledoc """
  Bundled how-to documentation the agent reads to learn **how Pepe itself works** -
  the authoritative source for configuring agents, channels, scheduled tasks, MCP
  servers, permissions, etc. Docs ship under `priv/docs/`; extra docs can live in
  `<PEPE_HOME>/docs/` (and override a built-in of the same name).

  Like skills, docs aren't loaded in full - only their titles are listed in the
  system prompt; the agent reads the relevant one on demand with the `docs` tool.
  """

  alias Pepe.Config

  @doc "User docs directory."
  def user_dir, do: Path.join(Config.home(), "docs")

  defp builtin_dir, do: Application.app_dir(:pepe, "priv/docs")

  @doc "All docs as `[{name, title}]` (user docs override built-ins by name)."
  def list do
    (docs_in(builtin_dir()) ++ docs_in(user_dir()))
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Read a doc's full Markdown by name (user dir wins over built-in)."
  def read(name) do
    user = Path.join(user_dir(), name <> ".md")
    builtin = Path.join(builtin_dir(), name <> ".md")

    cond do
      File.regular?(user) -> File.read(user)
      File.regular?(builtin) -> File.read(builtin)
      true -> {:error, :not_found}
    end
  end

  defp docs_in(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          {String.replace_suffix(file, ".md", ""), title(Path.join(dir, file))}
        end)

      _ ->
        []
    end
  end

  # The first Markdown heading is the doc's title.
  defp title(path) do
    with {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           content |> String.split("\n") |> Enum.find(&(String.trim(&1) != "")) do
      line |> String.replace_prefix("# ", "") |> String.trim() |> String.slice(0, 120)
    else
      _ -> ""
    end
  end
end
