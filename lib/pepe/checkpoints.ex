defmodule Pepe.Checkpoints do
  @moduledoc """
  What lets `/rewind` put an agent's files back, not only its conversation.

  ## The idea

  Before a file tool overwrites, edits or moves a file, the file is copied into a
  content-addressed store (`Pepe.Checkpoints.Store`); after the tool ran, what changed is
  written down as a *record*: path, hash before, hash after, mode. Records made during a turn
  wait in the session's *pending* list, and when the turn is committed into the conversation
  they are attached to it. Rewinding N turns then means: take the records of those turns,
  and for each path put back its earliest "before" (`Pepe.Checkpoints.Restore`), provided the
  file still holds exactly what the last tool call left there.

  Only what a tool changed is ever touched, and only inside the agent's workspace, the shared
  folder, the skills folder and the session's own working directory. Everything else a tool
  changed is recorded as *untracked* so a rewind can say so honestly instead of implying it
  covered it.

  ## What is covered

    * `write_file`, `edit_file` and `move_file`: exactly the paths they name.
    * `bash` and `run_script`: only when the agent has `checkpoint_shell` on, and then
      best-effort: a bounded snapshot of the working directory before and after (a file-count
      and byte cap, build output and dependencies skipped). A command that changes more than
      the cap allows is recorded as `partial` and the rewind says so.
    * Credential-looking files (`.env`, keys, certificates) are never copied, so they are
      never restored; files too large to copy are tracked by size and time only.
    * Anything a command does that is not one of the above (a database, the network, files
      outside the roots) is outside this feature, and no rewind can undo it.

  ## Keeping the log aligned with the conversation

  The turn log stores, per person message, a short fingerprint of its text. The log and the
  live history are aligned from the newest end and only while the fingerprints agree, so a
  compaction, an edited history or a restart can shorten what a rewind reaches but can never
  make it restore the wrong turn's files. Once a session has any record, every completed
  turn appends an entry (possibly empty) so the alignment stays contiguous.
  """

  require Logger

  alias Pepe.Agent.Workspace
  alias Pepe.Checkpoints.Restore
  alias Pepe.Checkpoints.Retention
  alias Pepe.Checkpoints.Snapshot
  alias Pepe.Checkpoints.Store
  alias Pepe.LLM.Message

  @file_tools ~w(write_file edit_file)
  @shell_tools ~w(bash run_script)
  @max_turns 200
  @preview 70

  ### recording: wrap a tool body

  @doc """
  Run `fun` (a tool's body) and, when the tool is one that changes files, record what it
  changed. Returns whatever `fun` returns and never lets checkpointing break the tool: any
  failure to snapshot or record is logged at debug level and swallowed.
  """
  @spec around(String.t(), map(), map(), (-> result)) :: result when result: term()
  def around(name, args, ctx, fun) when is_function(fun, 0) do
    case tracking(name, args, ctx) do
      nil ->
        fun.()

      tracking ->
        pre = safely(fn -> Snapshot.take(tracking.roots, skip: &store_path?/1) end)

        try do
          result = fun.()
          safely(fn -> record(tracking, pre, result) end)
          result
        catch
          kind, reason ->
            stack = __STACKTRACE__
            safely(fn -> record(tracking, pre, :crashed) end)
            :erlang.raise(kind, reason, stack)
        end
    end
  end

  # Decide what a tool call may change and which of that we may copy. `nil` = not tracked.
  defp tracking(name, args, ctx) do
    agent = ctx[:agent]

    with true <- enabled?(agent),
         {:ok, targets} <- targets(name, args, ctx, agent) do
      allowed = allowed_roots(Map.get(agent, :name), [ctx[:cwd_override]])
      {tracked, skipped} = split_targets(targets, allowed)

      if tracked == [] and skipped == [] do
        nil
      else
        %{
          tool: name,
          roots: tracked,
          skipped: skipped,
          scope: scope_root(ctx),
          session: ctx[:session_key]
        }
      end
    else
      _ -> nil
    end
  end

  @doc "Whether checkpoints are on for this agent (a map or struct with `:checkpoints`)."
  @spec enabled?(term()) :: boolean()
  def enabled?(nil), do: false
  def enabled?(agent) when is_map(agent), do: Map.get(agent, :checkpoints, true) != false
  def enabled?(_), do: false

  defp targets(name, %{"path" => path}, ctx, _agent) when name in @file_tools and is_binary(path),
    do: {:ok, [Workspace.resolve_in_ctx(path, ctx)]}

  defp targets("move_file", %{"from" => from, "to" => to}, ctx, _agent) when is_binary(from) and is_binary(to),
    do: {:ok, [Workspace.resolve_in_ctx(from, ctx), Workspace.resolve_in_ctx(to, ctx)]}

  defp targets(name, _args, ctx, agent) when name in @shell_tools do
    if Map.get(agent, :checkpoint_shell, false) == true, do: {:ok, [{:dir, Workspace.cwd_in_ctx(ctx)}]}, else: :none
  end

  defp targets(_name, _args, _ctx, _agent), do: :none

  # The directory a tool call works in; a record is filed under it.
  defp scope_root(ctx), do: ctx |> Workspace.cwd_in_ctx() |> Path.expand()

  @doc """
  The directories a rewind may write into for an agent: its workspace, its project's shared
  folder, the user skills folder, and any `extra` roots the surface owns (an editor's working
  directory, say).
  """
  @spec allowed_roots(String.t() | nil, [term()]) :: [Path.t()]
  def allowed_roots(agent_name, extra \\ []) do
    [
      if(agent_name, do: safe_dir(fn -> Workspace.dir(agent_name) end)),
      if(agent_name, do: safe_dir(fn -> Workspace.shared_dir(agent_name) end)),
      Workspace.skills_dir()
      | extra
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp safe_dir(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # Split what a tool call names into paths we may snapshot, and paths we must report as
  # untracked (outside the roots, or credential-looking).
  defp split_targets(targets, allowed) do
    Enum.reduce(targets, {[], []}, fn target, {tracked, skipped} ->
      path = target |> target_path() |> Path.expand()

      cond do
        not Enum.any?(allowed, &inside?(path, &1)) ->
          {tracked, skipped ++ [%{"path" => path, "reason" => "outside"}]}

        match?({:dir, _}, target) ->
          {tracked ++ [path], skipped}

        Snapshot.sensitive?(path) ->
          {tracked, skipped ++ [%{"path" => path, "reason" => "sensitive"}]}

        true ->
          {tracked ++ [path], skipped}
      end
    end)
  end

  defp target_path({:dir, path}), do: path
  defp target_path(path), do: path

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp store_path?(path), do: inside?(path, Path.expand(Store.root()))

  defp record(tracking, %{files: _} = pre, result) do
    post = Snapshot.take(tracking.roots, skip: &store_path?/1)
    changes = Snapshot.diff(pre, post)
    skipped = if match?({:ok, _}, result), do: tracking.skipped, else: []

    if changes != [] or skipped != [] do
      files =
        for change <- changes do
          keep_before(change, pre)
          %{"path" => change.path, "before" => change.before, "after" => change.after, "mode" => change.mode, "size" => change.size}
        end

      id = Store.new_id()

      record = %{
        "id" => id,
        "at" => System.os_time(:second),
        "tool" => tracking.tool,
        "partial" => pre.partial? or post.partial?,
        "files" => files,
        "skipped" => skipped
      }

      scope = Store.digest(tracking.scope)
      Store.write_record(scope, tracking.scope, record)
      add_pending(tracking.session, %{"scope" => scope, "id" => id})
    end

    :ok
  end

  defp record(_tracking, _pre, _result), do: :ok

  # The "before" copy is what a restore writes back, so it must exist before the record does.
  defp keep_before(%{before: sha, path: path}, pre) when is_binary(sha) do
    case pre.files[path] do
      %{data: data} when is_binary(data) -> Store.put_blob(data)
      _ -> :ok
    end
  end

  defp keep_before(_change, _pre), do: :ok

  defp add_pending(nil, _ref), do: :ok
  defp add_pending(key, ref), do: Store.update_log(key, fn log -> %{log | "pending" => log["pending"] ++ [ref]} end)

  defp safely(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("[checkpoints] #{Exception.message(e)}")
      nil
  catch
    kind, reason ->
      Logger.debug("[checkpoints] #{inspect({kind, reason})}")
      nil
  end

  ### the turn log

  @doc "A short, stable fingerprint of a person message, used to keep the log aligned."
  @spec fingerprint(map()) :: String.t()
  def fingerprint(%{"content" => content}) do
    bytes = if is_binary(content), do: content, else: inspect(content, limit: :infinity)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  def fingerprint(_message), do: "none"

  @doc """
  Attach what the finished run changed to the turn(s) it added. `fingerprints` is one per
  person message the run added (oldest first); the records go to the first. Does nothing for
  a session that has never recorded anything, and appends an empty entry per turn once it
  has, so the log stays aligned.
  """
  @spec commit_turn(term(), [String.t()]) :: :ok
  def commit_turn(_key, []), do: :ok

  def commit_turn(key, fingerprints) do
    log = Store.read_log(key)

    if log["pending"] != [] or log["turns"] != [] do
      now = System.os_time(:second)

      entries =
        fingerprints
        |> Enum.with_index()
        |> Enum.map(fn {fp, i} -> %{"fp" => fp, "at" => now, "refs" => if(i == 0, do: log["pending"], else: [])} end)

      Store.update_log(key, fn current ->
        turns = Enum.take(current["turns"] ++ entries, -@max_turns)
        %{current | "turns" => turns, "pending" => []}
      end)

      if log["pending"] != [], do: Retention.maybe_prune()
    end

    :ok
  end

  @doc "Drop the newest `count` entries (the conversation dropped that many turns)."
  @spec pop_turns(term(), pos_integer()) :: :ok
  def pop_turns(key, count) do
    if Store.read_log(key)["turns"] != [] do
      Store.update_log(key, fn log -> %{log | "turns" => Enum.drop(log["turns"], -count)} end)
    end

    :ok
  end

  @doc "Forget a session's log (a fresh conversation)."
  @spec forget_session(term()) :: :ok
  def forget_session(key), do: Store.delete_log(key)

  ### reading the log against the live history

  # Newest first, one `{fingerprint, entry | :unknown}` per person message. Alignment starts
  # at the newest end and stops at the first fingerprint that disagrees; every older turn is
  # `:unknown`, which means "nothing here can be restored", never "restore something".
  defp align(entries, messages) do
    fps = messages |> Enum.filter(&Message.person_turn?/1) |> Enum.map(&fingerprint/1) |> Enum.reverse()
    do_align(Enum.reverse(entries), fps)
  end

  defp do_align([%{"fp" => fp} = entry | entries], [fp | fps]), do: [{fp, entry} | do_align(entries, fps)]
  defp do_align(_entries, fps), do: Enum.map(fps, &{&1, :unknown})

  @doc """
  The newest `limit` person turns of a history, newest first, for a `/rewind` listing:
  `%{n:, preview:, files:}` where `files` is how many files that turn changed and can still
  be put back (`0` when it changed none, `nil` when nothing is known about it).
  """
  @spec turns(term(), [map()], pos_integer()) :: [map()]
  def turns(key, messages, limit \\ 10) do
    people = messages |> Enum.filter(&Message.person_turn?/1) |> Enum.reverse()

    Store.read_log(key)["turns"]
    |> align(messages)
    |> Enum.zip(people)
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {{{_fp, entry}, message}, n} -> %{n: n, preview: preview(message), files: files_in(entry)} end)
  end

  defp files_in(:unknown), do: nil
  defp files_in(%{"restored" => true}), do: 0

  defp files_in(%{"refs" => refs}) when is_list(refs) do
    refs
    |> Enum.flat_map(&read_ref/1)
    |> Enum.flat_map(fn record -> List.wrap(record["files"]) end)
    |> Enum.map(& &1["path"])
    |> Enum.uniq()
    |> length()
  end

  defp files_in(_entry), do: 0

  defp read_ref(%{"scope" => scope, "id" => id}) do
    case Store.read_record(scope, id) do
      {:ok, record} -> [record]
      :error -> []
    end
  end

  defp read_ref(_), do: []

  @doc "A one-line, single-spaced preview of a message's text."
  @spec preview(map()) :: String.t()
  def preview(%{"content" => content}) do
    text =
      cond do
        is_binary(content) -> content
        is_list(content) -> Enum.map_join(content, " ", &part_text/1)
        true -> ""
      end

    text = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(text) > @preview, do: String.slice(text, 0, @preview - 1) <> "…", else: text
  end

  def preview(_), do: ""

  defp part_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp part_text(%{"type" => type}) when is_binary(type), do: "[" <> type <> "]"
  defp part_text(_), do: ""

  ### rewinding files

  @doc """
  Put back the files the newest `count` turns of `messages` changed.

  Returns the `Pepe.Checkpoints.Restore` report plus `:unreached`, how many of those turns
  the log could not vouch for (older than tracking, compacted away, or with a history that
  no longer matches), and `:expired`, how many recorded changes had already been pruned.
  Options: `:roots` (required, the directories a path must sit inside) and `:dry_run`.
  """
  @spec restore(term(), [map()], pos_integer(), keyword()) :: map()
  def restore(key, messages, count, opts) do
    window = Store.read_log(key)["turns"] |> align(messages) |> Enum.take(count)
    known = for {_fp, %{} = entry} <- window, entry["restored"] != true, do: entry
    unreached = Enum.count(window, fn {_fp, entry} -> entry == :unknown end)

    refs = known |> Enum.reverse() |> Enum.flat_map(&List.wrap(&1["refs"]))
    records = Enum.flat_map(refs, &read_ref/1)
    report = Restore.run(records, Keyword.fetch!(opts, :roots), Keyword.take(opts, [:dry_run]))

    unless opts[:dry_run], do: mark_restored(key, length(window) - unreached)

    report
    |> Map.put(:unreached, unreached)
    |> Map.put(:expired, length(refs) - length(records))
    |> Map.put(:already, Enum.count(window, fn {_fp, entry} -> is_map(entry) and entry["restored"] == true end))
    |> Map.put(:turns, length(window))
  end

  # The restored entries stay in the log (the alignment needs them) but are flagged so a
  # second restore of the same turns does not read the files it just put back as "changed".
  # The aligned entries are always the newest ones, so it is the last `known` of the log.
  defp mark_restored(_key, known) when known <= 0, do: :ok

  defp mark_restored(key, known) do
    Store.update_log(key, fn log ->
      {older, newest} = Enum.split(log["turns"], max(length(log["turns"]) - known, 0))
      %{log | "turns" => older ++ Enum.map(newest, &Map.put(&1, "restored", true))}
    end)

    :ok
  end
end
