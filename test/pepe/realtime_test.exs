defmodule Pepe.RealtimeTest do
  use ExUnit.Case, async: false

  alias Pepe.Realtime

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_realtime_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "with nothing installed, no provider is known" do
    assert Realtime.providers() == %{}
    assert Realtime.get("anything") == nil
  end

  test "an installed provider is discoverable by its own name/0", %{home: home} do
    write_provider(home, "PepeRealtimeTest.Echo", "echo")

    assert %{"echo" => PepeRealtimeTest.Echo} = Realtime.providers()
    assert Realtime.get("echo") == PepeRealtimeTest.Echo
  end

  test "a module missing one of the required funs is not a candidate", %{home: home} do
    File.write!(Path.join([home, "plugins", "partial.exs"]), """
    defmodule PepeRealtimeTest.Partial do
      def name, do: "partial"
      def start(_agent, _opts, _sink), do: {:ok, :session}
      # missing push_audio/2 and stop/1
    end
    """)

    assert Realtime.providers() == %{}
    assert Realtime.get("partial") == nil
  end

  defp write_provider(home, module, name) do
    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule #{module} do
      @behaviour Pepe.Realtime.Provider
      def name, do: "#{name}"
      def start(_agent, _opts, _sink), do: {:ok, :session}
      def push_audio(_session, _chunk), do: :ok
      def stop(_session), do: :ok
    end
    """)
  end
end
