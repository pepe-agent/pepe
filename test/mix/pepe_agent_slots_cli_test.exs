defmodule Mix.Tasks.PepeAgentSlotsCliTest do
  @moduledoc """
  `mix pepe agent add NAME --slots slot:plugin,slot2:plugin2` sets an agent's own per-slot
  occupant override (Pepe.Slots.occupant/2) - separate from the installation-wide `mix pepe
  slot set`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_agentslots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "--slots parses comma-separated slot:plugin pairs into the agent's own override" do
    pepe(["agent", "add", "support", "--slots", "memory:example_memory,web_search:other_plugin"])

    agent = Config.get_agent("support")
    assert agent.slots == %{"memory" => "example_memory", "web_search" => "other_plugin"}
  end

  test "an agent with no --slots gets an empty override, unaffected by the flag existing" do
    pepe(["agent", "add", "plain"])
    assert Config.get_agent("plain").slots == %{}
  end

  test "a malformed pair (no colon) in the list is dropped, not a crash" do
    pepe(["agent", "add", "messy", "--slots", "memory:example_memory,garbage,web_search:x"])

    assert Config.get_agent("messy").slots == %{
             "memory" => "example_memory",
             "web_search" => "x"
           }
  end

  test "an unknown slot name is dropped and warned about, not silently persisted" do
    err = pepe_err(["agent", "add", "typo", "--slots", "memmory:example_memory,web_search:x"])

    assert err =~ "\"memmory\" isn't a known slot"
    assert Config.get_agent("typo").slots == %{"web_search" => "x"}
  end
end
