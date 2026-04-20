defmodule PepeWeb.LoginThrottle do
  @moduledoc """
  A tiny in-memory per-IP rate limiter for `POST /login`, so a password can't be
  brute-forced. Fixed window (default 10 attempts / 60s per client IP), kept in a
  public ETS table owned by this process - no database. A successful login resets
  the counter for that IP.

  Limits are overridable via `config :pepe, login_max_attempts:` / `login_window_s:`
  (handy in tests).
  """
  use GenServer

  @table :pepe_login_throttle

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Record an attempt for `key` (a client IP tuple). Returns `:ok` if allowed, or
  `{:error, seconds_left}` when the window is exhausted.
  """
  def check(key) do
    if table?() do
      do_check(key)
    else
      # limiter not running (e.g. a one-shot CLI): fail open rather than crash.
      :ok
    end
  end

  defp do_check(key) do
    now = System.monotonic_time(:second)
    window = window_s()

    case safe_lookup(key) do
      {count, start} when now - start < window ->
        if count >= max_attempts() do
          {:error, window - (now - start)}
        else
          :ets.insert(@table, {key, count + 1, start})
          :ok
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc "Clear the counter for `key` (call on a successful login)."
  def reset(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  defp safe_lookup(key) do
    case table?() && :ets.lookup(@table, key) do
      [{^key, count, start}] -> {count, start}
      _ -> nil
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp max_attempts, do: Application.get_env(:pepe, :login_max_attempts, 10)
  defp window_s, do: Application.get_env(:pepe, :login_window_s, 60)
end
