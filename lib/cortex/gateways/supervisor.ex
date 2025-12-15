defmodule Cortex.Gateways.Supervisor do
  @moduledoc """
  Supervises messaging gateways. A gateway starts only when both:

    * gateways are enabled for this run (`:start_gateways` app env) — set by the
      `serve` and `gateway` commands, but NOT by local `run`/`tui`, so a console
      session never spins up the Telegram poller (which would 409 against a real
      gateway already polling the same bot); and
    * its credentials are configured — e.g. a Telegram bot token in
      `~/.cortex/config.json` or `TELEGRAM_BOT_TOKEN`.
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
    if enabled?() and Cortex.Gateways.Telegram.enabled?() do
      [Cortex.Gateways.Telegram]
    else
      []
    end
  end

  # Gateways only run when this command asked for them (serve / gateway).
  defp enabled?, do: Application.get_env(:cortex, :start_gateways, false)
end
