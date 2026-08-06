defmodule Pepe.Gateways.PluginSupervisorTest do
  @moduledoc """
  A plugin's `Pepe.Gateways.Channel` child specs actually get supervised, in a crash
  domain isolated from the rest of `Pepe.Gateways.Supervisor` - `Pepe.Gateways.Telegram`
  is untouched by this test's plugin channel misbehaving.
  """
  use ExUnit.Case, async: false

  alias Pepe.Gateways.PluginSupervisor

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_gwplugin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "a plugin channel with no configured connection contributes no children" do
    pid = start_supervised!(%{id: PluginSupervisor, start: {PluginSupervisor, :start_link, [[]]}})
    assert Supervisor.count_children(pid).active == 0
  end

  test "a plugin channel with an active connection is started under this supervisor", %{home: home} do
    File.write!(Path.join([home, "plugins", "fake_channel.exs"]), """
    defmodule PepeGatewayPluginTest.EchoServer do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
      def init(:ok), do: {:ok, :ok}
    end

    defmodule PepeGatewayPluginTest.FakeChannel do
      @behaviour Pepe.Gateways.Channel
      def name, do: "fake_channel"
      def child_specs, do: [PepeGatewayPluginTest.EchoServer]
    end
    """)

    pid = start_supervised!(%{id: PluginSupervisor, start: {PluginSupervisor, :start_link, [[]]}})
    assert Supervisor.count_children(pid).active == 1
  end

  test "a plugin whose child_specs/0 raises is skipped, not fatal to the others", %{home: home} do
    File.write!(Path.join([home, "plugins", "raising_channel.exs"]), """
    defmodule PepeGatewayPluginTest.RaisingChannel do
      @behaviour Pepe.Gateways.Channel
      def name, do: "raising_channel"
      def child_specs, do: raise("boom, no config")
    end
    """)

    pid = start_supervised!(%{id: PluginSupervisor, start: {PluginSupervisor, :start_link, [[]]}})
    assert Supervisor.count_children(pid).active == 0
  end

  test "a plugin whose name/0 raises is skipped, not fatal to boot", %{home: home} do
    File.write!(Path.join([home, "plugins", "raising_name.exs"]), """
    defmodule PepeGatewayPluginTest.RaisingName do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
      def init(:ok), do: {:ok, :ok}
    end

    defmodule PepeGatewayPluginTest.RaisingNameChannel do
      @behaviour Pepe.Gateways.Channel
      def name, do: raise("boom, no config")
      def child_specs, do: [PepeGatewayPluginTest.RaisingName]
    end
    """)

    pid = start_supervised!(%{id: PluginSupervisor, start: {PluginSupervisor, :start_link, [[]]}})
    assert Supervisor.count_children(pid).active == 0
  end

  test "reload_plugins/0 reconciles children after a plugin's config changes", %{home: home} do
    start_supervised!(%{id: PluginSupervisor, start: {PluginSupervisor, :start_link, [[]]}})
    assert Supervisor.count_children(PluginSupervisor).active == 0

    File.write!(Path.join([home, "plugins", "late_channel.exs"]), """
    defmodule PepeGatewayPluginTest.LateServer do
      use GenServer
      def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
      def init(:ok), do: {:ok, :ok}
    end

    defmodule PepeGatewayPluginTest.LateChannel do
      @behaviour Pepe.Gateways.Channel
      def name, do: "late_channel"
      def child_specs, do: [PepeGatewayPluginTest.LateServer]
    end
    """)

    PluginSupervisor.reload_plugins()
    assert Supervisor.count_children(PluginSupervisor).active == 1
  end
end
