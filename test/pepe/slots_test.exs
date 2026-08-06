defmodule Pepe.SlotsTest do
  @moduledoc """
  Exercises `Pepe.Slots` against the real `memory` slot (its default, `Pepe.Memory.Builtin`,
  is core code with no external dependency) rather than a fixture slot definition, since the
  slot list itself is a closed, compile-time set - there's no way to register a throwaway
  slot just for this test, and using the real one is also the more honest test.
  """
  use ExUnit.Case, async: false

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_slots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "known?/1 and names/0 list the closed set of slots" do
    assert Pepe.Slots.known?("memory")
    assert Pepe.Slots.known?("web_search")
    refute Pepe.Slots.known?("does_not_exist")
    assert "memory" in Pepe.Slots.names()
  end

  test "degrade_mode/1: memory/web_search/compaction fall back on failure, sandbox refuses instead" do
    assert Pepe.Slots.degrade_mode("memory") == :fallback
    assert Pepe.Slots.degrade_mode("web_search") == :fallback
    assert Pepe.Slots.degrade_mode("compaction") == :fallback
    assert Pepe.Slots.degrade_mode("sandbox") == :error
  end

  test "with nothing configured, the default occupies the slot" do
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin
  end

  test "pinning a slot to an installed, slot-claiming plugin makes it the occupant", %{home: home} do
    write_memory_plugin(home, "PepeSlotTest.Alt", "alt_memory")
    Pepe.Config.put_slot("memory", "alt_memory")

    assert Pepe.Slots.occupant("memory") == PepeSlotTest.Alt
  end

  test "pinning to a name that isn't installed falls back to the default" do
    Pepe.Config.put_slot("memory", "not_installed")
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin
  end

  test "\"default\" and unset both resolve to the default" do
    Pepe.Config.put_slot("memory", "default")
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin
    Pepe.Config.delete_slot("memory")
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin
  end

  test "a plugin that exports the memory funs but claims a DIFFERENT slot is not a candidate", %{home: home} do
    File.write!(Path.join([home, "plugins", "wrong_slot.exs"]), """
    defmodule PepeSlotTest.Wrong do
      @behaviour Pepe.Memory.Backend
      def name, do: "wrong_slot_plugin"
      def slot, do: "web_search"
      def search(_agent, _query, _opts), do: {:ok, []}
    end
    """)

    Pepe.Config.put_slot("memory", "wrong_slot_plugin")

    # It never claims "memory" (its slot/0 says "web_search"), so pinning to its declared
    # name for the memory slot finds no match and falls back.
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin
  end

  test "candidates/1 always includes the default, plus any installed plugin that claims the slot", %{home: home} do
    assert [%{default?: true}] = Pepe.Slots.candidates("memory")

    write_memory_plugin(home, "PepeSlotTest.Cands", "cands_memory")
    names = Pepe.Slots.candidates("memory") |> Enum.map(& &1.name)
    assert "builtin" in names
    assert "cands_memory" in names
  end

  test "put_slot/2 refuses an unknown slot name" do
    assert {:error, :unknown_slot} = Pepe.Config.put_slot("not_a_real_slot", "whatever")
  end

  test "delete_slot/1 refuses an unknown slot name" do
    assert {:error, :unknown_slot} = Pepe.Config.delete_slot("not_a_real_slot")
  end

  test "a hand-edited config.json with a malformed \"slots\" shape doesn't crash reads or writes" do
    File.write!(Pepe.Config.path(), Jason.encode!(%{"slots" => ["memory"]}))

    assert Pepe.Config.slots_config() == %{}
    assert Pepe.Config.slot_occupant("memory") == nil
    assert Pepe.Slots.occupant("memory") == Pepe.Memory.Builtin

    assert :ok = Pepe.Config.put_slot("memory", "default")
    assert Pepe.Config.slots_config() == %{"memory" => "default"}
  end

  test "an agent's own `slots` override wins over the global setting", %{home: home} do
    write_memory_plugin(home, "PepeSlotTest.Global", "global_memory")
    write_memory_plugin(home, "PepeSlotTest.Mine", "my_memory")
    Pepe.Config.put_slot("memory", "global_memory")

    agent = %Pepe.Config.Agent{name: "solo", slots: %{"memory" => "my_memory"}}
    assert Pepe.Slots.occupant("memory", agent) == PepeSlotTest.Mine
    # An agent with no override still gets the global setting, unaffected.
    assert Pepe.Slots.occupant("memory", %Pepe.Config.Agent{name: "other"}) == PepeSlotTest.Global
  end

  test "a project's own default_slots wins over the global setting, but loses to an agent override", %{home: home} do
    write_memory_plugin(home, "PepeSlotTest.Glob2", "global_memory2")
    write_memory_plugin(home, "PepeSlotTest.Proj", "project_memory")
    write_memory_plugin(home, "PepeSlotTest.Mine2", "my_memory2")
    Pepe.Config.put_slot("memory", "global_memory2")
    Pepe.Config.add_project("acme", %{"default_slots" => %{"memory" => "project_memory"}})

    plain = %Pepe.Config.Agent{name: "acme/plain"}
    assert Pepe.Slots.occupant("memory", plain) == PepeSlotTest.Proj

    overridden = %Pepe.Config.Agent{name: "acme/overridden", slots: %{"memory" => "my_memory2"}}
    assert Pepe.Slots.occupant("memory", overridden) == PepeSlotTest.Mine2

    # A different project (or no project at all) is unaffected by acme's own default.
    unrelated = %Pepe.Config.Agent{name: "unrelated"}
    assert Pepe.Slots.occupant("memory", unrelated) == PepeSlotTest.Glob2
  end

  test "occupant/2 tolerates a plain map with no :slots key, degrading to no override" do
    # Some callers (tool ctx in tests, any caller with an agent-shaped map rather than a
    # real struct) pass something with `name` but no `slots` key at all.
    assert Pepe.Slots.occupant("memory", %{name: "zak"}) == Pepe.Memory.Builtin
  end

  defp write_memory_plugin(home, module_name, plugin_name) do
    File.write!(Path.join([home, "plugins", "#{plugin_name}.exs"]), """
    defmodule #{module_name} do
      @behaviour Pepe.Memory.Backend
      def name, do: "#{plugin_name}"
      def slot, do: "memory"
      def search(_agent, _query, _opts), do: {:ok, []}
    end
    """)
  end
end
