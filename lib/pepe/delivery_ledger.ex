defmodule Pepe.DeliveryLedger do
  @moduledoc """
  Durable record of a final reply owed to a channel, so a crash between "the turn
  finished" and "the message reached the platform" doesn't silently lose it. It's the
  one artifact a run can't get back once it's gone: the tokens are already spent, and
  until it's actually posted the text lives only in a process's local variable.

  Three checkpoints around a send:

      record(key, channel, meta, content)   # id, state "pending" - before any attempt
      mark_attempting(id)                   # state "attempting" - right before the call
      mark_delivered(id)                    # done - the row is simply removed
      mark_failed(id, reason)                # state "failed" - a definite rejection

  Backed by `Pepe.Store` (Mnesia, journaled to disk) - the same "survives a restart,
  not meant to be anyone's source of truth" tier session history already lives in. Each
  row carries a 24h TTL, refreshed on every checkpoint: old enough that it outlives a
  routine redeploy, short enough that a row nobody ever claims doesn't linger.

  `sweep_recoverable/2` is meant to run once per channel at boot, before that channel
  starts handling new work. On Pepe's single-node deployment this is simpler than it
  sounds: anything still `pending`/`attempting`/`failed` when the app comes back up
  belongs to a boot that's gone - nothing else can be mid-delivery yet, since the sweep
  is the first thing to run. Recovered rows are flagged `needs_marker: true` unless the
  send never even started (`pending`), so the channel can prefix a visible "might be a
  duplicate" note - honest at-least-once, never a silent duplicate. A row already retried
  `@max_attempts` times is dropped (logged, not silently) rather than returned again.
  """

  require Logger

  @namespace :delivery
  @ttl_seconds 86_400
  @max_attempts 3

  @doc """
  Record a reply as owed to `channel` (e.g. `"telegram"`). `meta` is whatever
  channel-specific routing info redelivery will need (chat id, thread, bot name, ...) -
  opaque to the ledger itself. Returns the obligation id.
  """
  @spec record(String.t(), String.t(), map(), String.t()) :: String.t()
  def record(session_key, channel, meta, content) do
    id = obligation_id(session_key, channel, meta, content)

    put(id, %{
      session_key: session_key,
      channel: channel,
      meta: meta,
      content: content,
      state: "pending",
      attempts: 0,
      last_error: nil
    })

    id
  end

  @doc "Right before the send attempt."
  @spec mark_attempting(String.t()) :: :ok
  def mark_attempting(id), do: update(id, &%{&1 | state: "attempting"})

  @doc "The send succeeded - nothing left to track."
  @spec mark_delivered(String.t()) :: :ok
  def mark_delivered(id) do
    Pepe.Store.delete(@namespace, id)
    :ok
  end

  @doc "The send definitely failed. Kept around (with a bumped attempt count) for the next sweep."
  @spec mark_failed(String.t(), String.t()) :: :ok
  def mark_failed(id, reason) do
    update(id, &%{&1 | state: "failed", last_error: to_string(reason), attempts: &1.attempts + 1})
  end

  @doc """
  Claim every recoverable row for `channel` that also matches `filter` (e.g. "this
  bot's own obligations" among several configured Telegram bots) - rows over the retry
  cap are dropped instead. Each returned row carries `needs_marker: true` unless the
  send never started (`state == "pending"`).
  """
  @spec sweep_recoverable(String.t(), (map() -> boolean())) :: [map()]
  def sweep_recoverable(channel, filter \\ fn _ -> true end) do
    @namespace
    |> Pepe.Store.all()
    |> Enum.filter(fn {_id, row} -> row.channel == channel and filter.(row) end)
    |> Enum.flat_map(fn {id, row} -> claim(id, row) end)
  end

  defp claim(id, %{attempts: attempts} = row) when attempts >= @max_attempts do
    Logger.warning("[delivery_ledger] abandoning #{id} after #{attempts} failed attempts: #{row.last_error}")
    Pepe.Store.delete(@namespace, id)
    []
  end

  defp claim(id, row) do
    [%{id: id, session_key: row.session_key, meta: row.meta, content: row.content, needs_marker: row.state != "pending"}]
  end

  defp put(id, row), do: Pepe.Store.put(@namespace, id, row, ttl: @ttl_seconds)

  defp update(id, fun) do
    case Pepe.Store.get(@namespace, id) do
      nil -> :ok
      row -> put(id, fun.(row))
    end
  end

  # Content-hash id: re-recording the identical reply for the same turn is idempotent
  # (harmless if a caller somehow records twice), while two different turns - even in
  # the same session - never collide.
  defp obligation_id(session_key, channel, meta, content) do
    payload = "#{session_key}|#{channel}|#{inspect(meta)}|#{content}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> String.slice(0, 24)
  end
end
