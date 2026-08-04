defmodule Pepe.LLM.Cooldown do
  @moduledoc """
  Stop retrying a model connection that just failed transiently (429/5xx) at the top of
  every failover chain - `Pepe.Agent.Runtime`'s `chat_with_failover/6` otherwise always
  starts at `hd(chain)` with zero cross-turn memory, so a model down for a minute gets hit
  by every single turn before falling through to its fallback.

  Keyed by `model.id || model.name`: `id` is the correct, stable identity, but an ad-hoc
  single-entry chain override (`opts[:model]` at Runtime's call site) and plenty of test
  fixtures carry `id: nil` - falling back to `name` there avoids every such connection
  colliding on the same `nil` key, at the cost of two differently-configured connections
  that happen to share a display name being treated as one. Accepted: a `name` collision is
  rare and merely cosmetic (a wasted skip, not a wrong answer), while an `id`-only key would
  make cooldown silently do nothing for the common ad-hoc-override case.

  In-memory (ETS `:set`) - a restart clears every cooldown, which is fine: the cost of one
  retried request against a still-down provider is exactly what this exists to avoid on the
  common path, not something worth guaranteeing across a restart.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Is `model` currently cooling down from a recent transient failure?"
  @spec cooling_down?(struct()) :: boolean()
  def cooling_down?(model) do
    ensure_table()

    case :ets.lookup(@table, key(model)) do
      [{_, until}] -> System.monotonic_time(:millisecond) < until
      [] -> false
    end
  end

  @doc "Mark `model` as cooling down after a transient failure. `reason` picks the duration."
  @spec mark_failed(struct(), term()) :: :ok
  def mark_failed(model, reason) do
    ensure_table()
    until = System.monotonic_time(:millisecond) + duration_ms(reason)
    :ets.insert(@table, {key(model), until})
    :ok
  end

  @doc "Clear a model's cooldown (a call to it just succeeded)."
  @spec clear(struct()) :: :ok
  def clear(model) do
    ensure_table()
    :ets.delete(@table, key(model))
    :ok
  end

  defp key(model), do: model.id || model.name

  # 429 gets the longer cooldown (a rate limit is usually a per-minute window); any other
  # transient reason (5xx, timeout, transport error) a shorter one - a blip is more likely to
  # have cleared already. Retry-After header parsing would be more precise, but no adapter in
  # Pepe.LLM threads response headers through today; this fixed duration captures nearly all
  # the value (stop hammering a connection that just failed) at a fraction of that diff.
  #
  # Public (not private) so a test can assert the two durations directly instead of sleeping
  # out a real 10s/30s window.
  @doc false
  def duration_ms({:http_error, 429, _}), do: 30_000
  def duration_ms(_), do: 10_000

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end
end
