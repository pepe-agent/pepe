defmodule Pepe.Gateways.DiscordSupervisor do
  @moduledoc """
  Runs one `Pepe.Gateways.Discord` per webhook connection that asked for ordinary messages
  (`receive_channel_messages`) and has a bot token, in a crash domain of its own, so a
  connection that keeps failing exhausts *this* supervisor's restart budget and not the one
  that also holds Telegram. `Pepe.Gateways.Supervisor` registers it `:transient` for the same
  reason it does `Pepe.Gateways.PluginSupervisor`: giving up is final until the next `reload/0`.

  A connection's child id carries a fingerprint of its bot token, so editing the token stops the
  old connection and opens a new one, while editing anything else (an unrelated connection, the
  agent it is bound to) leaves a live socket alone.
  """
  use Supervisor

  alias Pepe.Config
  alias Pepe.Gateways.Discord

  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @doc """
  Reconcile the running connections with the current config: close the ones that went away or
  changed token, open the ones that should run. A no-op when gateways are not enabled for this
  run or this supervisor is not up (a CLI one-shot).
  """
  @spec reload() :: :ok
  def reload do
    if Process.whereis(__MODULE__) do
      wanted = Map.new(specs(), &{&1.id, &1})
      children = Supervisor.which_children(__MODULE__)
      running = for {id, _pid, _type, _mods} <- children, do: id

      for id <- running, not is_map_key(wanted, id) do
        Supervisor.terminate_child(__MODULE__, id)
        Supervisor.delete_child(__MODULE__, id)
      end

      for {id, spec} <- wanted, id not in running, do: Supervisor.start_child(__MODULE__, spec)

      # A connection that gave up (a refused token) stays listed but stopped; being edited is
      # the operator saying "try again".
      for {id, :undefined, _type, _mods} <- children, is_map_key(wanted, id), do: Supervisor.restart_child(__MODULE__, id)
    end

    :ok
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(specs(), strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  @doc "Child specs for every connection that should have a gateway right now."
  @spec specs() :: [Supervisor.child_spec()]
  def specs do
    for {slug, entry} <- Config.webhooks(), Discord.active?(entry) do
      Supervisor.child_spec({Discord, slug}, id: {Discord, slug, :erlang.phash2(Discord.token(entry))})
    end
  end
end
