defmodule Pepe.Skills.Backup do
  @moduledoc """
  Snapshots of the whole user skills directory, so a maintenance pass that goes wrong can
  be undone in one command.

  The curator takes one before it changes anything (`reason: "curator"`), and a person can
  take one any time (`pepe skill curator backup`). `rollback/2` puts a snapshot back, and
  takes a `pre-rollback` snapshot of the current state first, so a rollback is itself
  undoable.

  A snapshot is a `.tar.gz` of every entry in `<PEPE_HOME>/skills/` (skills, packages and
  the `.archive/` of retired ones) except `.backups/` itself, named `<unix time>-<reason>`.
  Only the newest `@keep` are kept.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Ledger

  @keep 10
  @dir ".backups"

  @type snapshot :: %{id: String.t(), path: String.t(), at: integer(), reason: String.t(), bytes: non_neg_integer()}

  @doc "Where snapshots are kept."
  @spec dir() :: String.t()
  def dir, do: Path.join(Skills.user_dir(), @dir)

  @doc "Take a snapshot now. Returns its id."
  @spec create(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(reason, actor) do
    File.mkdir_p!(dir())
    id = "#{System.system_time(:second)}-#{slug(reason)}"
    path = Path.join(dir(), id <> ".tar.gz")

    with {:ok, entries} <- entries(),
         :ok <- :erl_tar.create(String.to_charlist(path), entries, [:compressed]) do
      prune()
      Ledger.log("*", "backup", actor, %{id: id, reason: reason})
      {:ok, id}
    end
  end

  @doc "Every snapshot, newest first."
  @spec list() :: [snapshot()]
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".tar.gz"))
        |> Enum.flat_map(&snapshot/1)
        |> Enum.sort_by(& &1.at, :desc)

      _ ->
        []
    end
  end

  @doc "Restore snapshot `id` (the newest when `nil`), after taking a `pre-rollback` snapshot of what is there now."
  @spec rollback(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(id, actor) do
    case pick(id) do
      nil ->
        {:error, :no_snapshot}

      snap ->
        with {:ok, _} <- create("pre-rollback", actor),
             :ok <- clear(),
             :ok <- :erl_tar.extract(String.to_charlist(snap.path), [:compressed, {:cwd, String.to_charlist(Skills.user_dir())}]) do
          Ledger.log("*", "rollback", actor, %{id: snap.id})
          {:ok, snap.id}
        end
    end
  end

  ###
  ### internals
  ###

  defp pick(nil), do: List.first(list())
  defp pick(id), do: Enum.find(list(), &(&1.id == id))

  defp snapshot(file) do
    id = String.replace_suffix(file, ".tar.gz", "")

    case String.split(id, "-", parts: 2) do
      [at, reason] ->
        case Integer.parse(at) do
          {at, ""} ->
            path = Path.join(dir(), file)
            [%{id: id, path: path, at: at, reason: reason, bytes: File.stat!(path).size}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # Every top-level entry except the snapshots themselves, as {name inside the archive, path}.
  defp entries do
    case File.ls(Skills.user_dir()) do
      {:ok, names} ->
        {:ok, for(n <- names, n != @dir, do: {String.to_charlist(n), String.to_charlist(Path.join(Skills.user_dir(), n))})}

      {:error, :enoent} ->
        {:ok, []}

      error ->
        error
    end
  end

  defp clear do
    case File.ls(Skills.user_dir()) do
      {:ok, names} ->
        names |> Enum.reject(&(&1 == @dir)) |> Enum.each(&File.rm_rf!(Path.join(Skills.user_dir(), &1)))
        :ok

      _ ->
        :ok
    end
  end

  defp prune do
    list() |> Enum.drop(@keep) |> Enum.each(&File.rm(&1.path))
  end

  defp slug(reason), do: reason |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
