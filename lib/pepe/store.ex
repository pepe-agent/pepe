defmodule Pepe.Store do
  @moduledoc """
  Disposable key/value store for runtime data (sessions, agent memory, ...), backed
  by **Mnesia** `disc_copies` - records live in RAM (ETS speed) and are journaled
  to disk, so they survive restarts but carry no 2 GB DETS limit.

  This is the *disposable* tier of Pepe's storage: configs (and souls) are the
  source of truth in `~/.pepe/config.json`; the store is regenerable cache. If a
  user backs up only their config and drops `~/.pepe/data/`, nothing essential is
  lost.

  Data is namespaced and may carry a TTL:

      Pepe.Store.put(:session, "telegram:42", history, ttl: 3600)
      Pepe.Store.get(:session, "telegram:42")   #=> history (or nil once expired)

  Keys and values are arbitrary Elixir terms. Expiry is lazy (checked on read);
  `expire/0` purges everything already past its TTL. The schema is created lazily
  on first use, on the local node, under `<PEPE_HOME>/data/mnesia`.
  """

  require Logger

  @table :pepe_store
  @ready {__MODULE__, :ready}

  @doc "Store `value` under `{namespace, key}`. `:ttl` (seconds) sets an expiry."
  def put(namespace, key, value, opts \\ []) do
    ensure_started()
    expires_at = ttl_to_expiry(opts[:ttl])
    safe(fn -> :mnesia.dirty_write({@table, {namespace, key}, value, expires_at}) end, :ok)
    :ok
  end

  @doc "Fetch the value under `{namespace, key}`, or `nil` (also nil once expired)."
  def get(namespace, key) do
    ensure_started()
    safe(fn -> read(namespace, key) end, nil)
  end

  defp read(namespace, key) do
    case :mnesia.dirty_read(@table, {namespace, key}) do
      [{@table, _key, value, expires_at}] -> fresh_or_nil(namespace, key, value, expires_at)
      _ -> nil
    end
  end

  defp fresh_or_nil(namespace, key, value, expires_at) do
    if expired?(expires_at) do
      delete(namespace, key)
      nil
    else
      value
    end
  end

  @doc "Remove `{namespace, key}`."
  def delete(namespace, key) do
    ensure_started()
    safe(fn -> :mnesia.dirty_delete(@table, {namespace, key}) end, :ok)
    :ok
  end

  @doc "All live `{key, value}` pairs in `namespace` (expired entries excluded)."
  def all(namespace) do
    ensure_started()

    safe(
      fn ->
        @table
        |> :mnesia.dirty_match_object({@table, {namespace, :_}, :_, :_})
        |> Enum.reject(fn {@table, _k, _v, exp} -> expired?(exp) end)
        |> Enum.map(fn {@table, {_ns, key}, value, _exp} -> {key, value} end)
      end,
      []
    )
  end

  @doc "Purge every entry whose TTL has passed. Returns the number removed."
  def expire do
    ensure_started()

    safe(
      fn ->
        @table
        |> :mnesia.dirty_match_object({@table, :_, :_, :_})
        |> Enum.filter(fn {@table, _k, _v, exp} -> expired?(exp) end)
        |> Enum.map(fn {@table, key, _v, _exp} -> :mnesia.dirty_delete(@table, key) end)
        |> length()
      end,
      0
    )
  end

  # The store is the *disposable* tier: a Mnesia hiccup - a table that won't load, a transient
  # timeout ({:timeout, [:pepe_store]}) - must degrade to a miss/no-op, never crash the caller's turn.
  # Before this, a `:ok = :mnesia.dirty_write(...)` match on such a return killed the whole agent turn.
  defp safe(fun, default) do
    fun.()
  rescue
    e ->
      Logger.warning("[store] #{Exception.message(e)}")
      default
  catch
    kind, reason ->
      Logger.warning("[store] #{inspect(kind)} #{inspect(reason)}")
      default
  end

  ###
  ### lazy bootstrap
  ###

  @doc "Create the schema/table and start Mnesia (idempotent, runs once)."
  def ensure_started do
    if :persistent_term.get(@ready, false), do: :ok, else: bootstrap()
  end

  # Serialize the bootstrap: two processes hitting the store for the first time at once would both
  # see the flag unset and both enter `do_start/0`, and one's `:mnesia.stop()` would land on the
  # other mid-write. A lock (with a second check inside it) makes exactly one process run it.
  defp bootstrap do
    :global.trans({{__MODULE__, :bootstrap}, self()}, fn ->
      unless :persistent_term.get(@ready, false) do
        do_start()
        :persistent_term.put(@ready, true)
      end
    end)

    :ok
  end

  defp do_start do
    dir = Path.join([Pepe.Config.home(), "data", "mnesia"])
    start_mnesia(dir)

    if ensure_table() == :orphaned do
      # The on-disk schema was created under a different node name - the classic case is a container
      # whose hostname (and so the Erlang node `pepe@<hostname>`) changed across a redeploy. The
      # disc_copies table is then bound to a node that isn't us, won't load, and every op returns
      # `{:timeout, [:pepe_store]}`. The store is disposable, so wipe the dir and recreate fresh under
      # this node rather than staying wedged. (A stable RELEASE_NODE prevents this in the first place.)
      Logger.warning("[store] mnesia table won't load (node name changed across a restart?); resetting the disposable store at #{dir}")
      :mnesia.stop()
      File.rm_rf!(dir)
      start_mnesia(dir)
      ensure_table()
    end

    :ok
  end

  # Point Mnesia at `dir` and start it with an on-disk schema (it may have auto-started in RAM, which
  # can't host disc_copies). Creating the schema while stopped makes the restart load a disc schema.
  defp start_mnesia(dir) do
    File.mkdir_p!(dir)
    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    _ = :mnesia.create_schema([node()])
    {:ok, _} = Application.ensure_all_started(:mnesia)
  end

  # Create the table (idempotent) and wait for it to load. `:ok`, or `:orphaned` when it can't load
  # within the window - a stale disc_copies from a different node name.
  defp ensure_table do
    case :mnesia.create_table(@table,
           attributes: [:key, :value, :expires_at],
           disc_copies: [node()],
           type: :set
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, @table}} -> :ok
    end

    case :mnesia.wait_for_tables([@table], 5_000) do
      :ok -> :ok
      _ -> :orphaned
    end
  end

  defp ttl_to_expiry(nil), do: nil
  defp ttl_to_expiry(seconds) when is_integer(seconds), do: System.os_time(:second) + seconds

  defp expired?(nil), do: false
  defp expired?(expires_at), do: System.os_time(:second) > expires_at
end
