defmodule Pepe.Skills.Lifecycle do
  @moduledoc """
  Taking a skill out of circulation and bringing it back, without ever losing it.

  An *archived* skill is moved (not copied, not deleted) into `<PEPE_HOME>/skills/.archive/`,
  which the skills index skips, so the agent stops seeing it and stops spending context on
  it. The move keeps the skill's whole shape - a loose `name.md` or a package directory with
  its `scripts/` and `references/` - plus a small `.archived.json` recording when it went
  and who put it there, so `restore/2` puts it back exactly as it was.

  Nothing in Pepe deletes a skill on its own. `archive/3` is the most destructive thing the
  background review and the curator can do, and it is recoverable; `purge/2` is the one
  irreversible operation and only a person's explicit command reaches it.

  Every operation here is *mechanism*. Whether a given actor is allowed to archive a given
  skill is decided by `Pepe.Skills.Ownership` in the callers (`Pepe.Tools.SkillManage`, the
  curator, the CLI); this module trusts its caller and writes the audit row.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stats

  @meta ".archived.json"

  @type archived :: %{name: String.t(), dir: String.t(), at: integer(), by: String.t(), kind: String.t()}

  @doc "Where archived skills live."
  @spec archive_dir() :: String.t()
  def archive_dir, do: Path.join(Skills.user_dir(), ".archive")

  @doc "Move the user copy of `name` into the archive."
  @spec archive(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def archive(name, actor, opts \\ []) do
    case Ownership.user_entry(name) do
      nil ->
        {:error, :not_found}

      {kind, path} ->
        dest = free_slot(name)

        with :ok <- File.mkdir_p(dest),
             :ok <- move_in(kind, name, path, dest),
             :ok <- File.write(Path.join(dest, @meta), Jason.encode!(meta(name, kind, actor))) do
          Stats.set_state(name, "archived")
          Ledger.log(name, "archive", actor, Map.new(opts))
          {:ok, dest}
        end
    end
  end

  @doc "Put the most recently archived copy of `name` back."
  @spec restore(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def restore(name, actor) do
    with :ok <- ensure_free(name),
         %{dir: dir, kind: kind} <- latest(name) || {:error, :not_archived},
         {:ok, target} <- move_out(kind, name, dir) do
      File.rm_rf(dir)
      Stats.set_state(name, "active")
      Ledger.log(name, "restore", actor)
      {:ok, target}
    end
  end

  @doc "Hand a skill of yours to the curator (it becomes agent-owned: background maintenance may update it)."
  @spec adopt(String.t(), String.t()) :: :ok | {:error, String.t()}
  def adopt(name, actor) do
    case Ownership.origin(name) do
      :user ->
        Stats.adopt(name, actor)
        Ledger.log(name, "adopt", actor)

      :agent ->
        {:error, "'#{name}' is already in the curator's care."}

      :missing ->
        {:error, "no skill of yours named '#{name}'."}

      other ->
        {:error, "'#{name}' is #{other} and not yours to hand over."}
    end
  end

  @doc "Take a skill back out of background maintenance (it becomes yours)."
  @spec release(String.t(), String.t()) :: :ok | {:error, String.t()}
  def release(name, actor) do
    if Ownership.origin(name) == :agent do
      Stats.release(name)
      Ledger.log(name, "release", actor)
    else
      {:error, "'#{name}' is not in the curator's care."}
    end
  end

  @doc "Pin or unpin a skill: a pinned skill is changed only by a person, present."
  @spec pin(String.t(), boolean(), String.t()) :: :ok | {:error, String.t()}
  def pin(name, pinned?, actor) do
    if Ownership.origin(name) == :missing do
      {:error, "no skill named '#{name}'."}
    else
      Stats.pin(name, pinned?)
      Ledger.log(name, if(pinned?, do: "pin", else: "unpin"), actor)
    end
  end

  @doc "Every archived skill, newest first."
  @spec archived() :: [archived()]
  def archived do
    case File.ls(archive_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.map(&read_meta(Path.join(archive_dir(), &1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.at, :desc)

      _ ->
        []
    end
  end

  @doc "Permanently delete every archived copy of `name`. The only irreversible skill operation."
  @spec purge(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, :not_archived}
  def purge(name, actor) do
    case Enum.filter(archived(), &(&1.name == name)) do
      [] ->
        {:error, :not_archived}

      copies ->
        Enum.each(copies, &File.rm_rf(&1.dir))
        Stats.forget(name)
        Ledger.log(name, "purge", actor, %{copies: length(copies)})
        {:ok, length(copies)}
    end
  end

  ###
  ### moving
  ###

  defp move_in(:loose, name, file, dest), do: rename(file, Path.join(dest, name <> ".md"))
  defp move_in(:package, name, dir, dest), do: rename(dir, Path.join(dest, name))

  defp move_out("loose", name, dir), do: place(Path.join(dir, name <> ".md"), Path.join(Skills.user_dir(), name <> ".md"))
  defp move_out("package", name, dir), do: place(Path.join(dir, name), Path.join(Skills.user_dir(), name))
  defp move_out(_kind, _name, _dir), do: {:error, :corrupt_archive}

  defp place(from, to) do
    File.mkdir_p!(Path.dirname(to))

    case rename(from, to) do
      :ok -> {:ok, to}
      error -> error
    end
  end

  # `File.rename/2` fails across filesystems; a skills directory and its own `.archive/` are
  # normally one filesystem, but a bind-mounted `skills/` inside a container is not guaranteed
  # to be, so fall back to copy-then-remove rather than fail to archive.
  defp rename(from, to) do
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

  defp ensure_free(name), do: if(Ownership.user_entry(name), do: {:error, :exists}, else: :ok)

  ###
  ### archive bookkeeping
  ###

  # The first free `<name>`, `<name>~2`, ... slot, so archiving a skill whose earlier copy is
  # already archived never overwrites (and therefore never loses) that copy.
  defp free_slot(name) do
    base = Path.join(archive_dir(), name)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 -> if not File.exists?(base), do: base
      n -> if not File.exists?("#{base}~#{n}"), do: "#{base}~#{n}"
    end)
  end

  defp latest(name), do: Enum.find(archived(), &(&1.name == name))

  defp meta(name, kind, actor),
    do: %{name: name, kind: Atom.to_string(kind), at: System.system_time(:second), by: actor}

  defp read_meta(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @meta)),
         {:ok, %{"name" => name, "kind" => kind, "at" => at, "by" => by}} <- Jason.decode(json) do
      %{name: name, dir: dir, at: at, by: by, kind: kind}
    else
      _ -> nil
    end
  end
end
