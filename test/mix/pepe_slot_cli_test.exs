defmodule Mix.Tasks.PepeSlotCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_slotcli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "list shows every known slot on its default when nothing is configured" do
    out = pepe(["slot", "list"])
    assert out =~ "memory"
    assert out =~ "web_search"
    assert out =~ "builtin"
    assert out =~ "duckduckgo"
  end

  test "set pins a slot to an installed plugin; list then shows it as the occupant", %{home: home} do
    File.write!(Path.join([home, "plugins", "cli_memory.exs"]), """
    defmodule PepeSlotCliTest.Alt do
      @behaviour Pepe.Memory.Backend
      def name, do: "cli_memory"
      def slot, do: "memory"
      def search(_agent, _query, _opts), do: {:ok, []}
    end
    """)

    assert pepe(["slot", "set", "memory", "cli_memory"]) =~ "set to"
    assert Config.slot_occupant("memory") == "cli_memory"
    assert pepe(["slot", "list"]) =~ "cli_memory"
  end

  test "set on an unknown slot is refused" do
    assert pepe_err(["slot", "set", "not_a_slot", "whatever"]) =~ "unknown slot"
    assert Config.slot_occupant("not_a_slot") == nil
  end

  test "clear reverts a pinned slot to its default" do
    Config.put_slot("memory", "whatever")
    assert pepe(["slot", "clear", "memory"]) =~ "reverted"
    assert Config.slot_occupant("memory") == nil
  end

  test "clear on an unknown slot is refused" do
    assert pepe_err(["slot", "clear", "not_a_slot"]) =~ "unknown slot"
  end
end
