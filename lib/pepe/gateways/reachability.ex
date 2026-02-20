defmodule Pepe.Gateways.Reachability do
  @moduledoc """
  Stop hammering a Telegram chat that's permanently gone — the bot was blocked, the
  group was deleted, the user deactivated their account. Telegram answers those with
  a **permanent** error (403 Forbidden, or 400 "chat not found"); retrying does
  nothing but burn API calls and log noise.

  Self-healing: a chat is marked dead on that error, skipped on every send while
  dead, and **cleared automatically** the moment a send to it succeeds again (e.g.
  the user un-blocked the bot) — no manual reset needed.

  Keyed by `{bot_name, chat_id}` so one bot's dead chat doesn't affect another's.
  In-memory (ETS) — a restart gives every target a fresh chance, which is fine: the
  cost of one wasted retry after a restart is negligible.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Is this chat marked dead for this bot?"
  @spec dead?(String.t(), term()) :: boolean()
  def dead?(bot_name, chat_id) do
    ensure_table()
    :ets.member(@table, {bot_name, to_string(chat_id)})
  end

  @doc "Mark a chat dead (permanent delivery failure)."
  @spec mark_dead(String.t(), term(), term()) :: :ok
  def mark_dead(bot_name, chat_id, reason \\ nil) do
    ensure_table()
    :ets.insert(@table, {{bot_name, to_string(chat_id)}, reason})
    :ok
  end

  @doc "Clear a chat's dead mark (e.g. a send to it just succeeded)."
  @spec clear(String.t(), term()) :: :ok
  def clear(bot_name, chat_id) do
    ensure_table()
    :ets.delete(@table, {bot_name, to_string(chat_id)})
    :ok
  end

  @doc "Does this Telegram API response mean the target is permanently gone?"
  @spec permanent_failure?(term()) :: boolean()
  def permanent_failure?({:ok, %{status: 403}}), do: true

  def permanent_failure?({:ok, %{status: 400, body: %{"description" => desc}}})
      when is_binary(desc) do
    String.contains?(desc, "chat not found") or String.contains?(desc, "user is deactivated") or
      String.contains?(desc, "bot was blocked")
  end

  def permanent_failure?(_), do: false

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  end
end
