defmodule Pepe.Gateways.Telegram.Throttle do
  @moduledoc """
  Per-chat rate limit for inbound Telegram messages.

  Each inbound message spawns a handler Task and, usually, a model call - real money and real
  scheduler pressure. With the default config (no `allowed_chats`/`allowed_users`) anyone who can
  message the bot could flood it: N messages, N tasks, N provider calls. This bounds that at the
  door, per chat, before the Task is spawned. Backed by `Hammer` (ETS, in-memory, fixed window),
  the same primitive as the widget's throttle.

  Limits are overridable via `config :pepe, telegram_rate_limit:` / `telegram_rate_window_s:`.
  """
  use Hammer, backend: :ets

  @doc "Record an inbound message for `chat_id`. `:ok` if allowed, `{:error, retry_ms}` if over."
  def check(chat_id) do
    scale = :timer.seconds(window_s())

    case hit("tg:#{chat_id}", scale, max_messages()) do
      {:allow, _count} -> :ok
      {:deny, retry_ms} -> {:error, retry_ms}
    end
  end

  @doc "Whether this inbound is within the rate limit (a thin boolean wrapper for the gateway)."
  def allow?(chat_id), do: check(chat_id) == :ok

  defp max_messages, do: Application.get_env(:pepe, :telegram_rate_limit, 30)
  defp window_s, do: Application.get_env(:pepe, :telegram_rate_window_s, 60)
end
