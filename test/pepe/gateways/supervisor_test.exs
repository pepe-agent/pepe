defmodule Pepe.Gateways.SupervisorTest do
  @moduledoc """
  `PluginSupervisor` must be registered `restart: :transient` under
  `Pepe.Gateways.Supervisor` - a plain `:permanent` child (the Supervisor default) would
  get respawned by the parent every time it exhausts its own restart budget, which is
  exactly the scenario the isolated crash domain (see `Pepe.Gateways.PluginSupervisor`'s
  moduledoc) exists to prevent from reaching Telegram.
  """
  use ExUnit.Case, async: false

  alias Pepe.Gateways.PluginSupervisor
  alias Pepe.Gateways.Supervisor, as: GatewaysSupervisor

  setup do
    prev = Application.get_env(:pepe, :start_gateways, false)
    Application.put_env(:pepe, :start_gateways, true)
    on_exit(fn -> Application.put_env(:pepe, :start_gateways, prev) end)
  end

  test "PluginSupervisor is a :transient child, not the :permanent default" do
    {:ok, {_flags, children}} = GatewaysSupervisor.init(:ok)

    plugin_child = Enum.find(children, &(&1.id == PluginSupervisor))
    assert plugin_child
    assert plugin_child.restart == :transient
  end

  test "the gateway supervisor declares its own explicit restart budget" do
    {:ok, {flags, _children}} = GatewaysSupervisor.init(:ok)
    assert flags.intensity > 0
    assert flags.period > 0
  end
end
