defmodule Cortex.Gateways.Supervisor do
  @moduledoc """
  Supervises messaging gateways. The Telegram gateway is started only when a bot
  token is configured (in `~/.cortex/config.json` or `TELEGRAM_BOT_TOKEN`), so a
  default install boots clean with no gateways running.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Restart the Telegram gateway for a clean slate (e.g. after a bot-token change).
  Most config changes are picked up live without this — the gateway reads config
  fresh each poll — so it's only needed to reset in-memory state.
  """
  def restart_telegram do
    child = Cortex.Gateways.Telegram
    _ = Supervisor.terminate_child(__MODULE__, child)

    case Supervisor.restart_child(__MODULE__, child) do
      {:error, :not_found} -> Supervisor.start_child(__MODULE__, child)
      other -> other
    end
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  defp children do
    if Cortex.Gateways.Telegram.enabled?() do
      [Cortex.Gateways.Telegram]
    else
      []
    end
  end
end
