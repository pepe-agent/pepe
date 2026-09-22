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
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stats

  @keep 10
  @dir ".backups"
  @staging ".rollback-staging"

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

  @doc """
  Restore snapshot `id` (the newest when `nil`), after taking a `pre-rollback` snapshot of
  what is there now.

  The snapshot is extracted into a staging directory *before* anything currently on disk is
  touched, and only once that extraction is verified to have actually produced the expected
  top-level entries does the live tree get cleared and replaced. A `create("pre-rollback", ...)`
  that runs first (before extraction is confirmed) risks evicting the very snapshot being
  restored through its own `prune/0` if the target is the oldest of an already-full `@keep`;
  clearing the live tree before extraction is confirmed risks leaving `skills/` permanently
  empty if extraction then fails. Staging first avoids both.
  """
  @spec rollback(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def rollback(id, actor) do
    case pick(id) do
      nil ->
        {:error, :no_snapshot}

      snap ->
        staging = staging_dir()
        File.rm_rf(staging)

        result =
          with :ok <- File.mkdir_p(staging),
               :ok <- :erl_tar.extract(String.to_charlist(snap.path), [:compressed, {:cwd, String.to_charlist(staging)}]),
               {:ok, _} <- create("pre-rollback", actor),
               :ok <- clear(),
               :ok <- swap(staging) do
            reconcile_stats()
            Ledger.log("*", "rollback", actor, %{id: snap.id})
            {:ok, snap.id}
          end

        File.rm_rf(staging)
        result
    end
  end

  ###
  ### internals
  ###

  defp pick(nil), do: List.first(list())
  defp pick(id), do: Enum.find(list(), &(&1.id == id))

  # A sibling of `Skills.user_dir()`, not inside it, so it is never itself part of what
  # `entries/0`/`clear/0` walk and can never be captured by a snapshot taken mid-rollback.
  defp staging_dir, do: Path.join(Path.dirname(Skills.user_dir()), @staging)

  # Moves every top-level entry the staged extraction produced into the (now cleared) live
  # tree. `File.rename/2` fails across filesystems, so fall back to copy-then-remove.
  defp swap(staging) do
    case File.ls(staging) do
      {:ok, names} -> Enum.reduce_while(names, :ok, &swap_one(&1, staging, &2))
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp swap_one(name, staging, :ok) do
    case move(Path.join(staging, name), Path.join(Skills.user_dir(), name)) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp move(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, _} ->
        with {:ok, _} <- File.cp_r(from, to) do
          File.rm_rf(from)
          :ok
        end
    end
  end

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

  # `Pepe.Skills.Stats` (SQLite) is not part of the snapshot: a rollback replaces the whole
  # `skills/` tree underneath it without touching a single row, so a skill's recorded
  # `state` can now disagree with where it actually physically ended up - restored out of
  # `.archive/` while still marked "archived", or the reverse. Bring every stats row back in
  # line with reality before anything reads it.
  defp reconcile_stats do
    archived_names = archive_dir_names()

    Enum.each(Stats.all(), fn {name, stat} ->
      cond do
        stat.state == "archived" and Ownership.user_entry(name) != nil -> Stats.set_state(name, "active")
        stat.state != "archived" and MapSet.member?(archived_names, name) -> Stats.set_state(name, "archived")
        true -> :ok
      end
    end)
  end

  defp archive_dir_names, do: MapSet.new(Lifecycle.archived(), & &1.name)

  defp slug(reason), do: reason |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
end
