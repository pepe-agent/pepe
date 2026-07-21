defmodule Pepe.Config.Journal do
  @moduledoc """
  A durable, append-only record of every `config.json` write: who/what made it, when,
  and which top-level sections changed - never the values. `config.json` can hold a
  real credential; a second file that copies values out of it would just be a second
  thing to secure, so this journal only ever names which keys changed, not what they
  changed to or from.

  The source is ambient (`put_source/1`, read back from the process dictionary by
  `Pepe.Config.Writer` at write time), the same "tag the caller, not every callee"
  shape `Pepe.Gateways.Telegram` already uses for its own bot/thread context -
  threading an explicit parameter through every one of the dozens of `Config.put_*`
  call sites across the CLI, every dashboard LiveView, every tool, and every
  scheduler would touch far more of the codebase to carry the same one string.

  Also flags a write whose `config.json` didn't match what `Pepe.Config.Writer`
  expected right before it ran - the file changed since this process's own last
  write, which only happens from a hand-edit, a second `mix pepe` process, or a
  restore from a `.bak` file. Surfaced as `"external" => true`, not as an error: the
  file-stamp cache in `Pepe.Config.load/1` is explicitly designed to pick up exactly
  this kind of out-of-band edit, so it must never be blocked, only made visible.

  Backed by `Pepe.Repo` (SQLite), not a `.jsonl` file - `recent/1`'s `ORDER BY id DESC
  LIMIT n` is a cheap index-range scan regardless of how large this ever grows, unlike
  the old "read the whole file, split every line, decode each" it replaced. No retention
  cap here: the query stays cheap even unbounded, so there's nothing to gain by adding
  one preemptively.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Pepe.Config.Journal.Entry
  alias Pepe.Repo

  @doc "Tag every config write this process makes with `source` (e.g. \"cli\", \"dashboard\", \"chat:manage_agent\")."
  @spec put_source(String.t()) :: :ok
  def put_source(source) when is_binary(source) do
    Process.put(:pepe_config_source, source)
    :ok
  end

  @doc "This process's tagged source, or \"unknown\" if `put_source/1` was never called."
  @spec source() :: String.t()
  def source, do: Process.get(:pepe_config_source, "unknown")

  @doc """
  Append one entry recording a config write - the top-level keys that actually
  changed between `old_config` and `new_config`. A no-op (nothing inserted) when
  nothing changed and the write wasn't flagged `external?`.
  """
  @spec record(String.t(), map(), map(), keyword()) :: :ok
  def record(source, old_config, new_config, opts \\ []) do
    changed = changed_keys(old_config, new_config)
    external? = opts[:external?] == true

    if changed != [] or external? do
      insert(%Entry{at: System.system_time(:second), source: source, changed: changed, external: external?})
    end

    :ok
  end

  # This is a diagnostic trail, not the write it's describing - `Config.save/1` above this
  # in `Writer.do_update/3` has already committed the real change to disk by the time this
  # runs. A Repo hiccup here (most commonly: no Repo running at all, the normal state of a
  # bare `ExUnit.Case` test that never touches operational data) must never turn an
  # already-successful config write into a raised exception - same reasoning, and the same
  # rescue-and-log shape, as `Pepe.Store`'s own tolerance for a Mnesia hiccup.
  defp insert(%Entry{} = entry) do
    Repo.insert!(entry)
  rescue
    e -> Logger.warning("[config journal] #{Exception.message(e)}")
  end

  @doc "The `limit` most recent journal entries, newest first."
  @spec recent(pos_integer()) :: [map()]
  def recent(limit \\ 200) do
    from(e in Entry, order_by: [desc: e.id], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  defp to_map(%Entry{} = e) do
    %{"at" => e.at, "source" => e.source, "changed" => e.changed, "external" => e.external}
  end

  defp changed_keys(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.filter(fn k -> Map.get(old, k) != Map.get(new, k) end)
    |> Enum.sort()
  end
end
