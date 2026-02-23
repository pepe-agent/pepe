defmodule Pepe.Gateways.Supervisor do
  @moduledoc """
  Supervises messaging gateways. A gateway starts only when both:

    * gateways are enabled for this run (`:start_gateways` app env) - set by the
      `serve` and `gateway` commands, but NOT by local `run`/`tui`, so a console
      session never spins up the Telegram poller (which would 409 against a real
      gateway already polling the same bot); and
    * its credentials are configured - e.g. a Telegram bot token in
      `~/.pepe/config.json` or `TELEGRAM_BOT_TOKEN`.
  """
  use Supervisor

  alias Pepe.Config
  alias Pepe.Gateways.Telegram

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Reconcile the running Telegram pollers with the current config: stop the ones
  that went away, (re)start the ones that should run - one poller per configured
  bot. Call this after adding/removing/editing a bot so the change takes effect
  without a full restart. (Token edits to an existing bot are picked up live, since
  each poll reads the token fresh.)
  """
  def reload_telegram do
    for {id, _pid, _type, _mods} <- Supervisor.which_children(__MODULE__),
        match?({Telegram, _}, id) do
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)
    end

    for spec <- telegram_specs(), do: Supervisor.start_child(__MODULE__, spec)
    :ok
  end

  # Kept for callers of the old name.
  def restart_telegram, do: reload_telegram()

  @impl true
  def init(_init_arg) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  defp children do
    if enabled?(), do: telegram_specs(), else: []
  end

  # One supervised poller per active bot, each tagged with a unique id so several
  # can coexist under this one_for_one supervisor.
  defp telegram_specs do
    Config.telegram_bots()
    |> Enum.filter(&Telegram.bot_active?/1)
    |> Enum.map(fn bot ->
      Supervisor.child_spec({Telegram, bot}, id: {Telegram, bot["name"]})
    end)
  end

  # Gateways only run when this command asked for them (serve / gateway).
  defp enabled?, do: Application.get_env(:pepe, :start_gateways, false)
end
