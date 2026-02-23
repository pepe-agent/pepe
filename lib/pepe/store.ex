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

  @table :pepe_store
  @ready {__MODULE__, :ready}

  @doc "Store `value` under `{namespace, key}`. `:ttl` (seconds) sets an expiry."
  def put(namespace, key, value, opts \\ []) do
    ensure_started()
    expires_at = ttl_to_expiry(opts[:ttl])
    :ok = :mnesia.dirty_write({@table, {namespace, key}, value, expires_at})
    :ok
  end

  @doc "Fetch the value under `{namespace, key}`, or `nil` (also nil once expired)."
  def get(namespace, key) do
    ensure_started()

    case :mnesia.dirty_read(@table, {namespace, key}) do
      [{@table, _key, value, expires_at}] ->
        if expired?(expires_at) do
          delete(namespace, key)
          nil
        else
          value
        end

      [] ->
        nil
    end
  end

  @doc "Remove `{namespace, key}`."
  def delete(namespace, key) do
    ensure_started()
    :ok = :mnesia.dirty_delete(@table, {namespace, key})
    :ok
  end

  @doc "All live `{key, value}` pairs in `namespace` (expired entries excluded)."
  def all(namespace) do
    ensure_started()

    @table
    |> :mnesia.dirty_match_object({@table, {namespace, :_}, :_, :_})
    |> Enum.reject(fn {@table, _k, _v, exp} -> expired?(exp) end)
    |> Enum.map(fn {@table, {_ns, key}, value, _exp} -> {key, value} end)
  end

  @doc "Purge every entry whose TTL has passed. Returns the number removed."
  def expire do
    ensure_started()

    @table
    |> :mnesia.dirty_match_object({@table, :_, :_, :_})
    |> Enum.filter(fn {@table, _k, _v, exp} -> expired?(exp) end)
    |> Enum.map(fn {@table, key, _v, _exp} -> :mnesia.dirty_delete(@table, key) end)
    |> length()
  end

  ###
  ### lazy bootstrap
  ###

  @doc "Create the schema/table and start Mnesia (idempotent, runs once)."
  def ensure_started do
    if :persistent_term.get(@ready, false) do
      :ok
    else
      do_start()
      :persistent_term.put(@ready, true)
      :ok
    end
  end

  defp do_start do
    dir = Path.join([Pepe.Config.home(), "data", "mnesia"])
    File.mkdir_p!(dir)

    # Mnesia may have auto-started with an in-RAM schema, which can't host
    # disc_copies tables. Stop it, point it at our dir, and create the on-disk
    # schema while stopped so the restart loads a disc-resident schema.
    :mnesia.stop()
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))
    _ = :mnesia.create_schema([node()])
    {:ok, _} = Application.ensure_all_started(:mnesia)

    case :mnesia.create_table(@table,
           attributes: [:key, :value, :expires_at],
           disc_copies: [node()],
           type: :set
         ) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, @table}} -> :ok
    end

    :ok = :mnesia.wait_for_tables([@table], 10_000)
  end

  defp ttl_to_expiry(nil), do: nil
  defp ttl_to_expiry(seconds) when is_integer(seconds), do: System.os_time(:second) + seconds

  defp expired?(nil), do: false
  defp expired?(expires_at), do: System.os_time(:second) > expires_at
end
