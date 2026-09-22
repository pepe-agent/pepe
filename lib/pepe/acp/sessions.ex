defmodule Pepe.ACP.Sessions do
  @moduledoc """
  What outlives an ACP connection: which conversations exist, where each was opened,
  which agent owns it, and who currently has it open.

  The conversation itself (the message history) is not stored here. It lives where every
  other surface's history lives, in `Pepe.Agent.SessionPersistence`, under the key
  `acp:<id>`; the `Pepe.Agent.Session` for that key saves it on its own after every
  change, because the ACP server starts it with `persist: true`. This module keeps the
  small facts around it that an editor's "history" panel needs and that the history
  file has no room for:

    * a **metadata** file per session (`<PEPE_HOME>/data/acp_sessions/<id>.json`): the
      directory the editor opened, the agent, and when it was last used. One file per
      session, written by whichever `pepe acp` process owns that session, so two
      editors on two projects never contend for the same file.
    * a **lock** file beside it (`<id>.lock`) holding the OS pid of the process that has
      the session open. Two processes appending to one history is the only way this
      feature could lose someone's conversation, so the second one is told no, with the
      pid and the way out (`session/fork`), instead of racing. A lock left behind by a
      process that died is recognized (its pid is gone) and taken over.

  The lock is per **OS process**, not per connection: a `pepe acp` process serves exactly
  one editor over its stdio, so the two are the same thing in production. Two
  `Pepe.ACP.Server` processes inside one VM (which only tests and embedding code ever
  start) therefore both read a lock as `:ours` and may share a session; nothing here
  arbitrates between them. That is deliberate and left unguarded: the tests that pin the
  hand-over between two connections rely on it, and no real deployment can reach it.

  ## Ids

  `sess_` followed by 24 characters of URL-safe base64 from 18 random bytes. Not a
  counter (a per-connection counter would give every editor session `sess_1`, and the
  second run would collide with the first) and not guessable: the id is the only
  credential `session/load` asks for. Ids arrive from the client and end up in a file
  name, so `valid_id?/1` is checked before any path is built from one.

  ## Retention

  Editor conversations accumulate faster than chat ones (one per project per day is
  ordinary), so the store is bounded: on every connection start `prune/0` deletes
  sessions untouched for 30 days and, past 200 sessions, the oldest ones, together
  with their history and title. A session another live process has open is never
  pruned. The numbers are fixed, not settings: the point is that the store cannot grow
  without bound, not that it is tunable.

  ## When it is off

  Under the test environment nothing is written (the same backstop
  `Pepe.Agent.Session` has for its global flag), so a stray test cannot write into a
  real `~/.pepe`. A test that wants persistence sets `:acp_persist_sessions` to `true`.
  """

  alias Pepe.Agent.SessionPersistence
  alias Pepe.Agent.SessionTitles
  alias Pepe.Config

  @retention_days 30
  @max_sessions 200
  @page_size 50
  @title_length 80

  @typedoc "A session's metadata, as stored."
  @type meta :: %{required(String.t()) => term()}

  @doc "Whether editor sessions are saved to disk at all."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:pepe, :acp_persist_sessions, Application.get_env(:pepe, :env) != :test)

  @doc "A fresh, unguessable session id."
  @spec generate_id() :: String.t()
  def generate_id, do: "sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc "Whether `id` is shaped like an id this module generates (and is safe in a file name)."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(~r/\Asess_[A-Za-z0-9_-]{16,64}\z/, id)
  def valid_id?(_other), do: false

  @doc "The `Pepe.Agent.Session` key for an ACP session id."
  @spec key(String.t()) :: String.t()
  def key(id), do: "acp:" <> id

  ###
  ### metadata
  ###

  @doc "Record a session that is about to have its first turn. Idempotent."
  @spec create(String.t(), String.t(), String.t() | nil) :: :ok
  def create(id, cwd, agent) do
    if enabled?() and valid_id?(id) do
      now = now()

      case fetch(id) do
        {:ok, _existing} -> :ok
        :error -> write(id, %{"id" => id, "cwd" => cwd, "agent" => agent, "created_at" => now, "updated_at" => now})
      end
    else
      :ok
    end
  end

  @doc "The metadata of `id`, or `:error` when there is none (or persistence is off)."
  @spec fetch(term()) :: {:ok, meta()} | :error
  def fetch(id) do
    with true <- enabled?() and valid_id?(id),
         {:ok, body} <- File.read(meta_path(id)),
         {:ok, %{"id" => ^id} = meta} <- Jason.decode(body) do
      {:ok, meta}
    else
      _ -> :error
    end
  end

  @doc "Point a session at the directory its editor has open now."
  @spec update_cwd(String.t(), String.t()) :: :ok
  def update_cwd(id, cwd), do: update(id, %{"cwd" => cwd})

  @doc """
  Mark a session as just used (and remember which agent it ended up with). Returns the
  timestamp it was stamped with, so what the editor is told and what is on disk agree.
  """
  @spec touch(String.t(), String.t() | nil) :: String.t()
  def touch(id, agent) do
    at = now()
    update(id, %{"updated_at" => at, "agent" => agent})
    at
  end

  defp update(id, changes) do
    case fetch(id) do
      {:ok, meta} -> write(id, Map.merge(meta, changes))
      :error -> :ok
    end
  end

  defp write(id, meta) do
    File.mkdir_p!(dir())
    tmp = meta_path(id) <> ".tmp"

    # Same write-then-rename as SessionPersistence: a kill mid-write must not leave a
    # half-written file that reads back as a session that does not exist.
    with :ok <- File.write(tmp, Jason.encode!(meta)) do
      File.rename(tmp, meta_path(id))
    end

    :ok
  rescue
    # Losing the ability to remember a session must not cost the user the turn they are
    # in the middle of.
    _ -> :ok
  end

  ###
  ### listing
  ###

  @doc """
  One page of the sessions that belong to `agent`, newest first, optionally only those
  opened in `cwd`. `cursor` is the opaque value a previous page returned.

  Returns `{:ok, metas, next_cursor | nil}`, or `{:error, :bad_cursor}` for one this
  module did not issue (an unknown cursor is an error, never "the whole list again").
  """
  @spec page(String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, [meta()], String.t() | nil} | {:error, :bad_cursor}
  def page(agent, cwd, cursor) do
    with {:ok, after_position} <- decode_cursor(cursor) do
      ordered =
        agent
        |> all_for_agent()
        |> Enum.filter(&(is_nil(cwd) or &1["cwd"] == cwd))
        |> Enum.sort_by(&{&1["updated_at"], &1["id"]}, fn {ta, ia}, {tb, ib} -> ta > tb or (ta == tb and ia < ib) end)
        |> Enum.drop_while(&(after_position != nil and not after?(&1, after_position)))

      {page, rest} = Enum.split(ordered, @page_size)
      {:ok, page, if(rest == [] or page == [], do: nil, else: encode_cursor(List.last(page)))}
    end
  end

  # Sessions that have had at least one turn (meta is only written when the first one
  # starts), and belong to the agent this connection is bound to.
  defp all_for_agent(agent) do
    wanted = canonical_agent(agent)
    Enum.filter(all(), &(canonical_agent(&1["agent"]) == wanted))
  end

  defp all do
    case enabled?() && File.ls(dir()) do
      {:ok, files} ->
        for file <- files, String.ends_with?(file, ".json"), {:ok, meta} <- [read_meta(file)], do: meta

      _ ->
        []
    end
  end

  defp read_meta(file) do
    with {:ok, body} <- File.read(Path.join(dir(), file)),
         {:ok, %{"id" => id, "updated_at" => updated} = meta} when is_binary(updated) <- Jason.decode(body),
         true <- valid_id?(id) do
      {:ok, meta}
    else
      _ -> :error
    end
  end

  @doc """
  The one spelling of an agent's name. A session can record its agent as a bare name
  (`editor`), a project handle (`default/editor`) or as "the default" (`nil`), and the
  same agent must compare equal whichever way it was written down. A name that is not
  a configured agent (any more) comes back as it was given.
  """
  @spec canonical_agent(String.t() | nil) :: String.t() | nil
  def canonical_agent(nil), do: canonical_agent(Config.default_agent_name())

  def canonical_agent(name) when is_binary(name) do
    case Config.get_agent(name) do
      %{name: canonical} -> canonical
      nil -> name
    end
  end

  def canonical_agent(_other), do: nil

  defp encode_cursor(meta), do: Base.url_encode64(Jason.encode!([meta["updated_at"], meta["id"]]), padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, [updated, id]} when is_binary(updated) and is_binary(id) <- Jason.decode(raw) do
      {:ok, {updated, id}}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  defp decode_cursor(_other), do: {:error, :bad_cursor}

  # Strictly after the cursor in the (newest first, id ascending) order the page uses.
  defp after?(meta, {updated, id}), do: meta["updated_at"] < updated or (meta["updated_at"] == updated and meta["id"] > id)

  @doc """
  What an editor shows for a session: its generated title, else the opening of what
  was asked first, else the folder name, else a placeholder.
  """
  @spec title(meta()) :: String.t()
  def title(meta) do
    key = key(meta["id"])
    present(SessionTitles.get(key)) || present(preview(key)) || present(leaf(meta["cwd"])) || "New thread"
  end

  defp preview(key) do
    with {:ok, _agent, messages, _pii, _pending} <- SessionPersistence.load(key),
         %{"content" => content} when is_binary(content) <-
           Enum.find(messages, &Pepe.LLM.Message.person_turn?/1) do
      content |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, @title_length)
    else
      _ -> nil
    end
  end

  defp leaf(cwd) when is_binary(cwd), do: Path.basename(cwd)
  defp leaf(_other), do: nil

  defp present(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp present(_other), do: nil

  ###
  ### who has it open
  ###

  @doc """
  Take the lock on `id` for this OS process. `:ok` when it is ours (freshly taken, taken
  over from a dead process, or already ours), `{:error, {:held, os_pid}}` when another
  live process has it open.
  """
  @spec claim(String.t()) :: :ok | {:error, {:held, String.t() | nil}}
  def claim(id) do
    if enabled?() and valid_id?(id) do
      File.mkdir_p!(dir())
      do_claim(id, 1)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp do_claim(id, retries) do
    path = lock_path(id)

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, System.pid())
        File.close(io)
        :ok

      {:error, :eexist} ->
        case holder(path) do
          :ours ->
            :ok

          {:alive, pid} ->
            {:error, {:held, pid}}

          :gone when retries > 0 ->
            _ = File.rm(path)
            do_claim(id, retries - 1)

          :gone ->
            {:error, {:held, nil}}
        end

      # A lock we cannot create (read-only home, say) is not a reason to refuse the
      # editor: the history could not be saved either, and that is already best-effort.
      {:error, _other} ->
        :ok
    end
  end

  @doc "Give the lock on `id` back, if this process is the one holding it."
  @spec release(String.t()) :: :ok
  def release(id) do
    if enabled?() and valid_id?(id) and holder(lock_path(id)) == :ours, do: File.rm(lock_path(id))
    :ok
  end

  defp holder(path) do
    with {:ok, body} <- File.read(path),
         pid = String.trim(body),
         true <- Regex.match?(~r/\A\d+\z/, pid) do
      cond do
        pid == System.pid() -> :ours
        alive?(pid) -> {:alive, pid}
        true -> :gone
      end
    else
      _ -> :gone
    end
  end

  # `kill -0` sends nothing; it only reports whether the pid exists. "Operation not
  # permitted" still means it exists (another user's process). Where there is no `kill`
  # (Windows) the answer is "not alive": the lock then only protects against a second
  # editor window on the same platform that has it, which is the honest limit there.
  defp alive?(pid) do
    case :os.type() do
      {:unix, _} ->
        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_out, 0} -> true
          {out, _status} -> String.contains?(out, "not permitted")
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  ###
  ### retention
  ###

  @doc """
  Delete what is past retention: sessions untouched for #{@retention_days} days, then the oldest
  beyond #{@max_sessions}. Never touches a session that is open: not one another live process
  holds, and not one this very process has claimed either (the sweep runs concurrently with the
  connection's first requests, so a thread the person just picked from the history panel may
  be a 31-day-old one).
  """
  @spec prune() :: :ok
  def prune do
    if enabled?() do
      cutoff = DateTime.utc_now() |> DateTime.add(-@retention_days * 86_400) |> DateTime.to_iso8601()
      newest_first = Enum.sort_by(all(), & &1["updated_at"], :desc)
      {kept, overflow} = Enum.split(newest_first, @max_sessions)
      expired = Enum.filter(kept, &(&1["updated_at"] < cutoff))

      for meta <- overflow ++ expired, not open?(meta["id"]), do: delete(meta["id"])
    end

    :ok
  rescue
    _ -> :ok
  end

  defp open?(id) do
    case holder(lock_path(id)) do
      :ours -> true
      {:alive, _pid} -> true
      :gone -> false
    end
  end

  @doc "Forget a session entirely: metadata, lock, history and title."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    if valid_id?(id) do
      File.rm(meta_path(id))
      File.rm(lock_path(id))
      SessionPersistence.delete(key(id))
      SessionTitles.delete(key(id))
    end

    :ok
  end

  ###
  ### paths
  ###

  defp dir, do: Path.join([Config.home(), "data", "acp_sessions"])
  defp meta_path(id), do: Path.join(dir(), id <> ".json")
  defp lock_path(id), do: Path.join(dir(), id <> ".lock")
  @doc "The timestamp format the store uses (ISO 8601, UTC), so callers agree with it."
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
