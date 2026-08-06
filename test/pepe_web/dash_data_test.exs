defmodule PepeWeb.DashDataTest do
  @moduledoc "Small form-parsing helpers shared across the dashboard's LiveViews."
  use ExUnit.Case, async: false

  alias PepeWeb.DashData

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_dashdata_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  describe "parse_slots/1" do
    test "keeps known slots, drops blank values" do
      assert DashData.parse_slots(%{"memory" => "example_memory", "harness" => ""}) ==
               %{"memory" => "example_memory"}
    end

    test "drops a key outside Pepe.Slots.names/0 - a typo, or a forged param" do
      # The <select> this normally reads from only ever emits known slot names, but
      # nothing stops a direct POST from naming an arbitrary key. Mirrors
      # Pepe.Config.put_slot/2's own {:error, :unknown_slot} for the installation-wide
      # setting, which had no equivalent guard on this, per-agent path until this.
      assert DashData.parse_slots(%{"memory" => "x", "bogus_slot" => "y"}) == %{"memory" => "x"}
    end

    test "nil is treated as nothing submitted" do
      assert DashData.parse_slots(nil) == %{}
    end

    test "a non-map param (a forged request) doesn't crash - treated as nothing submitted" do
      assert DashData.parse_slots("not a map") == %{}
      assert DashData.parse_slots(["also", "not", "a", "map"]) == %{}
    end
  end
end
