defmodule Pepe.Skills.Manage do
  @moduledoc """
  The one guarded way to create, change and retire a skill.

  Every path that lets an agent write a skill (the `skill_manage` tool, the background
  review, the curator) ends here, so the rules are enforced once:

    * **Whose it is.** `Pepe.Skills.Ownership` decides. A person, present in a
      conversation (*foreground*), may change their own skills and agent-written ones; the
      permission gate has already put the call in front of them. A run with nobody present
      (*background*) may create a new skill and change only skills an agent wrote and nobody
      pinned; bundled, installed, pinned and hand-written skills are refused with a reason
      the run can act on ("say what is wrong with it and suggest `pepe skill adopt`").
    * **Read before write.** A background run must have opened the exact file in the same
      run (`Pepe.Skills.Tracker`) before it may patch, rewrite, overwrite or remove it, so
      it works from what is on disk and not from what it remembers.
    * **Shape.** A legal name, a size cap, something to summarise (`Pepe.Skills.Lint`
      errors refuse the write; its warnings come back with the result so the agent fixes them
      in the same turn).
    * **Safety.** `Pepe.Skills.Sentinel` scans everything written; a `:danger` verdict
      refuses it. Support files go only under `references/`, `templates/`, `scripts/` or
      `assets/`, by a relative path that stays inside the skill and crosses no symlink.
    * **Traceability.** Each change stores the bytes it replaced and the bytes it wrote
      (`Pepe.Skills.Snapshots`), a ledger row with both hashes (`Pepe.Skills.Ledger`), and a
      stats update. `undo/2` reverses any one of them, and refuses when the file has changed
      since, so it can never silently discard a later edit.

  Nothing here deletes a skill: `delete/2` archives it, which is recoverable.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Lint
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Sentinel
  alias Pepe.Skills.Snapshots
  alias Pepe.Skills.Stats
  alias Pepe.Skills.Tracker

  @max_doc 100_000
  @max_file 1_048_576
  @subdirs ~w(references templates scripts assets)
  @file_actions ~w(create edit patch write_file remove_file undo)

  @type result :: {:ok, map()} | {:error, String.t()}

  ###
  ### create / edit / patch / files / delete
  ###

  @doc "Create the skill `name` (a package: `<name>/SKILL.md`) with `content`."
  @spec create(String.t(), String.t(), keyword()) :: result()
  def create(name, content, opts \\ []) do
    ctx = ctx(opts)

    locked(name, fn ->
      with :ok <- check_name(name),
           :ok <- check_free(name, ctx),
           {:ok, findings} <- check_doc(name, content, nil),
           :ok <- check_safe(content, "SKILL.md") do
        path = Path.join([Skills.user_dir(), name, "SKILL.md"])
        write_change(ctx, "create", name, "SKILL.md", path, content, findings)
      end
    end)
  end

  @doc "Replace the whole entry doc of `name`."
  @spec edit(String.t(), String.t(), keyword()) :: result()
  def edit(name, content, opts \\ []) do
    ctx = ctx(opts)

    locked(name, fn ->
      with :ok <- authorize(name, ctx),
           {:ok, path} <- doc_path(name),
           :ok <- require_read(name, nil, ctx),
           {:ok, findings} <- check_doc(name, content, name),
           :ok <- check_safe(content, "SKILL.md") do
        write_change(ctx, "edit", name, "SKILL.md", path, content, findings)
      end
    end)
  end

  @doc """
  Replace `old` with `new` in the entry doc, or in the support file `opts[:file_path]`.
  `old` must match exactly once unless `opts[:replace_all]`.
  """
  @spec patch(String.t(), String.t(), String.t(), keyword()) :: result()
  def patch(name, old, new, opts \\ []) do
    ctx = ctx(opts)
    file = opts[:file_path]

    locked(name, fn ->
      with :ok <- authorize(name, ctx),
           {:ok, rel, path} <- target(name, file),
           :ok <- require_read(name, file, ctx),
           {:ok, current} <- read(path),
           {:ok, updated} <- replace(current, old, new, opts[:replace_all] == true),
           {:ok, findings} <- check_content(name, rel, updated),
           :ok <- check_safe(updated, rel) do
        write_change(ctx, "patch", name, rel, path, updated, findings)
      end
    end)
  end

  @doc "Write (create or overwrite) the support file `file_path` of the package `name`."
  @spec write_file(String.t(), String.t(), String.t(), keyword()) :: result()
  def write_file(name, file_path, content, opts \\ []) do
    ctx = ctx(opts)

    locked(name, fn ->
      with :ok <- authorize(name, ctx),
           {:ok, path} <- support_path(name, file_path),
           :ok <- require_read_if_exists(name, file_path, path, ctx),
           :ok <- check_file_content(content),
           :ok <- check_safe(content, file_path) do
        write_change(ctx, "write_file", name, file_path, path, content, [])
      end
    end)
  end

  @doc "Remove the support file `file_path` (its bytes stay in the snapshots, so `undo/2` restores it)."
  @spec remove_file(String.t(), String.t(), keyword()) :: result()
  def remove_file(name, file_path, opts \\ []) do
    ctx = ctx(opts)

    locked(name, fn ->
      with :ok <- authorize(name, ctx),
           {:ok, path} <- support_path(name, file_path),
           :ok <- require_read(name, file_path, ctx),
           {:ok, before} <- read(path) do
        remove_change(ctx, name, file_path, path, before)
      end
    end)
  end

  @doc """
  Retire the skill `name` into the archive. `opts[:absorbed_into]` names the skill its
  content now lives in; with `require_target: true` (the consolidation pass) that skill must
  exist, or the archive is refused.
  """
  @spec delete(String.t(), keyword()) :: result()
  def delete(name, opts \\ []) do
    ctx = ctx(opts)

    locked(name, fn ->
      with :ok <- authorize(name, ctx),
           :ok <- check_target(name, opts[:absorbed_into], opts[:require_target] == true),
           {:ok, dest} <- Lifecycle.archive(name, ctx.actor, absorbed_into: opts[:absorbed_into]) do
        {:ok, %{action: "archive", name: name, message: "Archived '#{name}' (recoverable: #{dest}).", findings: []}}
      else
        {:error, :not_found} -> {:error, "no skill named '#{name}'."}
        other -> other
      end
    end)
  end

  ###
  ### undo
  ###

  @doc """
  Reverse one ledger entry. Refuses when the file is no longer what that entry left, unless
  `opts[:force]`, so a later change is never thrown away by accident.
  """
  @spec undo(String.t(), String.t(), keyword()) :: result()
  def undo(entry_id, actor, opts \\ []) do
    case Ledger.get(entry_id) do
      nil ->
        {:error, "no ledger entry '#{entry_id}'."}

      %{action: "archive"} = e ->
        undo_archive(e, actor)

      %{action: action} = e when action in @file_actions ->
        locked(e.skill, fn -> undo_file(e, actor, opts) end)

      %{action: action} ->
        {:error, "a '#{action}' entry cannot be undone one by one; use `pepe skill curator rollback` for a library snapshot."}
    end
  end

  defp undo_archive(e, actor) do
    case Lifecycle.restore(e.skill, actor) do
      {:ok, dest} -> {:ok, %{action: "undo", name: e.skill, message: "Restored '#{e.skill}' from the archive (#{dest}).", findings: []}}
      {:error, reason} -> {:error, "could not restore '#{e.skill}': #{inspect(reason)}"}
    end
  end

  defp undo_file(e, actor, opts) do
    detail = Ledger.detail(e)
    file = detail["file"]

    with true <- is_binary(file) or {:error, "that entry does not record which file it changed."},
         {:ok, path} <- undo_path(e.skill, file),
         :ok <- check_unchanged(path, detail["after"], opts[:force] == true) do
      undo_change(e, actor, file, path, detail["before"])
    end
  end

  # Undoing a create archives the whole package (recoverable) instead of leaving an empty
  # directory behind; everything else puts the previous bytes back, or removes a file the
  # entry had added.
  defp undo_change(%{action: "create", skill: name}, actor, "SKILL.md", _path, nil) do
    case Lifecycle.archive(name, actor) do
      {:ok, dest} -> {:ok, %{action: "undo", name: name, message: "Undid the creation of '#{name}': archived it (#{dest}).", findings: []}}
      {:error, reason} -> {:error, "could not archive '#{name}': #{inspect(reason)}"}
    end
  end

  defp undo_change(e, actor, file, path, before_hash) do
    with {:ok, restored} <- restore_bytes(path, before_hash) do
      finish_undo(%{actor: actor}, e, file, path, restored)
    end
  end

  # The file an entry changed, wherever it is now. A skill archived since has nothing to
  # restore into; say so instead of recreating it elsewhere.
  defp undo_path(name, "SKILL.md"), do: doc_path(name)
  defp undo_path(name, file), do: support_path(name, file)

  defp check_unchanged(path, after_hash, force?) do
    current = current_hash(path)

    if force? or current == after_hash do
      :ok
    else
      {:error,
       "the file changed after that entry (it no longer matches what the entry wrote), so undoing it would discard a later change. Read the file and fix it by hand, or pass --force."}
    end
  end

  defp restore_bytes(path, nil) do
    # The entry created this file: undoing it removes it, keeping the bytes in the snapshots.
    case File.rm(path) do
      :ok -> {:ok, :removed}
      {:error, reason} -> {:error, "could not remove #{Path.basename(path)}: #{inspect(reason)}"}
    end
  end

  defp restore_bytes(path, before_hash) do
    with {:ok, bytes} <- snapshot_bytes(before_hash),
         :ok <- write_atomic(path, bytes) do
      {:ok, bytes}
    end
  end

  defp snapshot_bytes(hash) do
    case Snapshots.get(hash) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "the stored copy of the previous content is gone (snapshots are pruned after a while)."}
    end
  end

  defp finish_undo(ctx, e, file, path, :removed) do
    Stats.bump_patch(e.skill)

    id =
      Ledger.record(e.skill, "undo", ctx.actor, %{"undoes" => e.id, "file" => file, "before" => hash_of(e, "after"), "after" => nil})

    {:ok,
     %{
       action: "undo",
       name: e.skill,
       file: file,
       entry: id,
       message: "Undid #{e.id}: removed #{Path.relative_to(path, Skills.user_dir())}.",
       findings: []
     }}
  end

  defp finish_undo(ctx, e, file, path, bytes) do
    Stats.bump_patch(e.skill)
    after_hash = Snapshots.put(bytes)

    id =
      Ledger.record(e.skill, "undo", ctx.actor, %{"undoes" => e.id, "file" => file, "before" => hash_of(e, "after"), "after" => after_hash})

    {:ok,
     %{
       action: "undo",
       name: e.skill,
       file: file,
       entry: id,
       message: "Undid #{e.id}: #{Path.relative_to(path, Skills.user_dir())} is back to what it was.",
       findings: []
     }}
  end

  defp hash_of(e, key), do: Ledger.detail(e)[key]

  ###
  ### authorization and guards
  ###

  defp ctx(opts) do
    %{
      actor: Keyword.get(opts, :actor, "agent"),
      origin: Keyword.get(opts, :origin, :foreground),
      run: Keyword.get(opts, :run)
    }
  end

  defp check_name(name) do
    if Ownership.valid_name?(name),
      do: :ok,
      else:
        {:error, "'#{inspect(name)}' is not a legal skill name: lowercase letters, digits, hyphens and underscores, 64 characters at most."}
  end

  defp check_free(name, ctx) do
    case {Ownership.origin(name), ctx.origin} do
      {:missing, _} -> :ok
      {:bundled, _} -> {:error, "'#{name}' ships with Pepe and cannot be replaced; pick another name."}
      {_, :background} -> {:error, "a skill named '#{name}' already exists; read it and patch it instead of creating another."}
      {_, :foreground} -> {:error, "a skill named '#{name}' already exists; use edit or patch."}
    end
  end

  defp authorize(name, %{origin: :background}) do
    case Ownership.background_check(name) do
      :ok -> :ok
      {:refused, reason} -> {:error, reason}
    end
  end

  defp authorize(name, %{origin: :foreground}) do
    case Ownership.origin(name) do
      :bundled ->
        {:error, "'#{name}' ships with Pepe and is read-only; create a skill under another name to customise it."}

      :installed ->
        {:error,
         "'#{name}' was installed from a source that owns it, and an update would overwrite the change; make a copy under another name instead."}

      :missing ->
        {:error, "no skill named '#{name}'."}

      _ ->
        :ok
    end
  end

  defp require_read(_name, _file, %{origin: :foreground}), do: :ok

  defp require_read(name, file, %{origin: :background, run: run}) do
    if Tracker.read?(run, name, file),
      do: :ok,
      else:
        {:error,
         "read before write: open #{describe_target(name, file)} in this run first (the `skill` tool for the entry doc, `read_file` for a support file), then retry the write from what it returned."}
  end

  defp require_read_if_exists(name, file, path, ctx) do
    if File.exists?(path), do: require_read(name, file, ctx), else: :ok
  end

  defp describe_target(name, nil), do: "'#{name}'"
  defp describe_target(name, file), do: "'#{name}' file #{file}"

  defp check_target(_name, _target, false), do: :ok

  defp check_target(_name, nil, true),
    do: {:error, "archiving during consolidation needs `absorbed_into`: the skill this one's content now lives in."}

  defp check_target(name, name, true), do: {:error, "a skill cannot be absorbed into itself."}

  defp check_target(_name, target, true) do
    if Ownership.origin(target) == :missing,
      do: {:error, "`absorbed_into` names '#{target}', which does not exist; create or patch the umbrella first."},
      else: :ok
  end

  ###
  ### content checks
  ###

  defp check_doc(_name, content, _existing) when not is_binary(content), do: {:error, "`content` must be text."}

  defp check_doc(name, content, existing) do
    dir = if existing, do: package_dir(name)

    cond do
      not String.valid?(content) ->
        {:error, "the content is not valid UTF-8."}

      String.length(content) > @max_doc ->
        {:error, "the entry doc is #{String.length(content)} characters; the limit is #{@max_doc}. Move depth into references/ files."}

      true ->
        lint(content, name, dir)
    end
  end

  defp check_content(name, "SKILL.md", text), do: check_doc(name, text, name)

  defp check_content(_name, _file, text) do
    with :ok <- check_file_content(text), do: {:ok, []}
  end

  defp check_file_content(content) when not is_binary(content), do: {:error, "`file_content` must be text."}
  defp check_file_content(content) when byte_size(content) > @max_file, do: {:error, "that file is over #{@max_file} bytes."}
  defp check_file_content(content), do: if(String.valid?(content), do: :ok, else: {:error, "the file is not valid UTF-8 text."})

  defp lint(content, name, dir) do
    findings = Lint.content(content, name: name, dir: dir)

    if Lint.errors?(findings),
      do: {:error, "the skill is not valid yet:\n" <> Lint.format(Enum.filter(findings, &(&1.severity == :error)))},
      else: {:ok, findings}
  end

  defp check_safe(text, label) do
    scan =
      Sentinel.merge([Sentinel.scan(text) | code_scan(text, label)])

    if scan.verdict == :danger,
      do: {:error, "the security scan refused #{label}:\n" <> Sentinel.report(scan)},
      else: :ok
  end

  defp code_scan(text, label) do
    if String.starts_with?(label, "scripts/") or String.starts_with?(label, "templates/") do
      [safe_code_scan(text, label)]
    else
      []
    end
  end

  defp safe_code_scan(text, label) do
    Sentinel.scan_code(text, label)
  rescue
    _ -> %{verdict: :safe, findings: []}
  end

  defp replace(current, old, new, replace_all?) do
    cond do
      not is_binary(old) or old == "" -> {:error, "`old_string` must be the exact text to replace."}
      not is_binary(new) -> {:error, "`new_string` must be text (empty removes the match)."}
      true -> apply_replace(current, old, new, replace_all?, count(current, old))
    end
  end

  defp apply_replace(_current, old, _new, _all?, 0),
    do: {:error, "`old_string` was not found. Open the file again and copy the exact text:\n#{String.slice(old, 0, 200)}"}

  defp apply_replace(current, old, new, true, _n), do: {:ok, String.replace(current, old, new)}
  defp apply_replace(current, old, new, false, 1), do: {:ok, String.replace(current, old, new, global: false)}

  defp apply_replace(_current, _old, _new, false, n),
    do: {:error, "`old_string` matches #{n} places; add surrounding text to make it unique, or pass replace_all."}

  defp count(text, pattern), do: length(:binary.matches(text, pattern))

  ###
  ### paths
  ###

  defp doc_path(name) do
    case Ownership.user_doc(name) do
      nil -> {:error, "no skill named '#{name}'."}
      path -> {:ok, path}
    end
  end

  defp package_dir(name) do
    case Ownership.user_entry(name) do
      {:package, dir} -> dir
      _ -> nil
    end
  end

  defp target(name, nil) do
    with {:ok, path} <- doc_path(name), do: {:ok, "SKILL.md", path}
  end

  defp target(name, file) do
    with {:ok, path} <- support_path(name, file), do: {:ok, file, path}
  end

  defp support_path(name, file) do
    with {:package, dir} <- package_or_error(name),
         :ok <- check_relative(file),
         path = Path.join(dir, file),
         :ok <- check_inside(dir, path),
         :ok <- check_no_symlinks(dir, file) do
      {:ok, path}
    end
  end

  defp package_or_error(name) do
    case Ownership.user_entry(name) do
      {:package, _} = found -> found
      {:loose, _} -> {:error, "'#{name}' is a single file, so it has no references/, templates/ or scripts/ to write into."}
      nil -> {:error, "no skill named '#{name}'."}
    end
  end

  defp check_relative(file) when is_binary(file) do
    segments = String.split(file, "/")

    cond do
      Path.type(file) != :relative or String.contains?(file, ["..", "\\", <<0>>]) ->
        {:error, "`file_path` must be relative and stay inside the skill."}

      byte_size(file) > 200 ->
        {:error, "`file_path` is too long."}

      match?([_], segments) or hd(segments) not in @subdirs ->
        {:error, "support files go under #{Enum.join(@subdirs, ", ")}, for example references/notes.md."}

      not Enum.all?(segments, &Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, &1)) ->
        {:error, "`file_path` may only use letters, digits, dots, hyphens and underscores in each part."}

      true ->
        :ok
    end
  end

  defp check_relative(_), do: {:error, "`file_path` is required."}

  defp check_inside(dir, path) do
    if String.starts_with?(Path.expand(path), Path.expand(dir) <> "/"),
      do: :ok,
      else: {:error, "`file_path` escapes the skill directory."}
  end

  # Refuses a path with a symlink anywhere in it, so a link planted inside a package cannot
  # carry a write out of it.
  defp check_no_symlinks(dir, file) do
    file
    |> Path.split()
    |> Enum.scan(dir, &Path.join(&2, &1))
    |> Enum.find(&symlink?/1)
    |> case do
      nil -> :ok
      bad -> {:error, "#{Path.relative_to(bad, dir)} is a symbolic link; refusing to write through it."}
    end
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  ###
  ### writing
  ###

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, "#{Path.basename(path)} does not exist."}
    end
  end

  defp write_change(ctx, action, name, rel, path, content, findings) do
    before = if File.regular?(path), do: File.read!(path)

    case write_atomic(path, content) do
      :ok -> finish(ctx, action, name, rel, before, content, findings)
      {:error, reason} -> {:error, "could not write #{rel}: #{inspect(reason)}"}
    end
  end

  defp remove_change(ctx, name, rel, path, before) do
    case File.rm(path) do
      :ok -> finish(ctx, "remove_file", name, rel, before, nil, [])
      {:error, reason} -> {:error, "could not remove #{rel}: #{inspect(reason)}"}
    end
  end

  defp finish(ctx, action, name, rel, before, after_bytes, findings) do
    before_hash = if before, do: Snapshots.put(before)
    after_hash = if after_bytes, do: Snapshots.put(after_bytes)

    id = Ledger.record(name, action, ctx.actor, %{"file" => rel, "before" => before_hash, "after" => after_hash})
    record_stats(ctx, action, name)

    {:ok, %{action: action, name: name, file: rel, entry: id, message: message(action, name, rel), findings: findings}}
  end

  defp record_stats(ctx, "create", name), do: Stats.record_created(name, ctx.actor, ctx.origin == :background)
  defp record_stats(_ctx, _action, name), do: Stats.bump_patch(name)

  defp message("create", name, _rel), do: "Created skill '#{name}'."
  defp message("remove_file", name, rel), do: "Removed #{rel} from '#{name}'."
  defp message(_action, name, rel), do: "Updated #{rel} in '#{name}'."

  defp write_atomic(path, bytes) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp current_hash(path) do
    case File.read(path) do
      {:ok, bytes} -> Snapshots.hash(bytes)
      _ -> nil
    end
  end

  # One writer per skill at a time, across every actor: a curator pass and a foreground edit
  # of the same skill are serialised instead of interleaving their read-modify-write.
  defp locked(name, fun) do
    case :global.trans({{__MODULE__, name}, self()}, fun, [node()], 20) do
      :aborted -> {:error, "'#{name}' is being changed by something else right now; try again in a moment."}
      result -> result
    end
  end
end
