defmodule PepeWeb.WidgetThrottle do
  @moduledoc """
  Rate limits prompts sent through the embeddable chat widget, so a token that sits
  in public page source can't be hammered. Only applied to widget-scoped connections
  (`Pepe.Config.add_api_token/1`, `kind: "widget"`) - every other surface (plain API
  tokens, the dashboard, Telegram, ...) is unaffected. Backed by `Hammer` (ETS,
  in-memory, fixed window), mirroring the same shape as `PepeWeb.LoginThrottle`.

  Limits are overridable via `config :pepe, widget_rate_limit:` / `widget_rate_window_s:`
  (handy in tests).
  """
  use Hammer, backend: :ets

  @doc """
  Record a prompt for `key` (the widget connection's session id). Returns `:ok` if
  allowed, or `{:error, retry_after_ms}` when the window is exhausted.
  """
  def check(key) do
    scale = :timer.seconds(window_s())

    case hit(key, scale, max_prompts()) do
      {:allow, _count} -> :ok
      {:deny, retry_ms} -> {:error, retry_ms}
    end
  end

  defp max_prompts, do: Application.get_env(:pepe, :widget_rate_limit, 20)
  defp window_s, do: Application.get_env(:pepe, :widget_rate_window_s, 60)
end
