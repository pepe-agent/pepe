defmodule Pepe.Gateways.PluginSupervisor do
  @moduledoc """
  Runs every installed plugin's `Pepe.Gateways.Channel` child specs, in its own crash
  domain, separate from `Pepe.Gateways.Supervisor`'s own children (Telegram). A
  crash-looping third-party channel (a flaky websocket, a bad reconnect loop) exhausts
  *this* supervisor's own restart budget and shuts it down - and because
  `Pepe.Gateways.Supervisor` registers it with `restart: :transient`, that shutdown is
  final: the parent does NOT restart it (transient means "don't restart on a normal/
  `:shutdown` exit"), so the plugin-channel domain goes dark until the next
  `reload_plugins/0` instead of respawning and potentially draining the *parent's* own
  restart budget too - which a plain `:permanent` child (the Supervisor default) would do,
  taking Telegram down with it.

  A plugin whose `name/0` or `child_specs/0` itself raises, or whose `child_specs/0`
  returns something `Supervisor.child_spec/2` can't normalize, is skipped (logged, `[]`)
  rather than aborting `init/1` - which would otherwise fail this supervisor's own start
  and, with it, the boot of `mix pepe serve`/`gateway` itself.
  """
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Reconcile running plugin channels with the current set of installed plugins/config - call after installing/removing/reconfiguring one."
  def reload_plugins do
    for {id, _pid, _type, _mods} <- Supervisor.which_children(__MODULE__) do
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)
    end

    for spec <- plugin_specs(), do: Supervisor.start_child(__MODULE__, spec)
    :ok
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(plugin_specs(), strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  defp plugin_specs do
    for mod <- Pepe.Plugins.implementing([{:name, 0}, {:child_specs, 0}]),
        spec <- safe_plugin_specs(mod),
        do: spec
  end

  # mod.name/0 and building the actual child_spec both run in the boot/reload process,
  # same as mod.child_specs/0 - all three belong under the one rescue, not just the last.
  defp safe_plugin_specs(mod) do
    for raw <- mod.child_specs() do
      Supervisor.child_spec(raw, id: {:plugin_gateway, mod.name(), System.unique_integer([:positive])})
    end
  rescue
    e ->
      Logger.warning("[gateways] #{inspect(mod)} raised building its channel spec(s): #{Exception.message(e)}; skipping")
      []
  end
end
