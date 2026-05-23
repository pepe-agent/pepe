defmodule Pepe.Tools.SetRouteTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.SetRoute

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_setroute_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "A", system_prompt: "x"})
    Config.put_agent(%Agent{name: "B", system_prompt: "x"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "allow adds a directed route" do
    assert {:ok, msg} = SetRoute.run(%{"from" => "A", "to" => "B", "action" => "allow"}, %{})
    assert msg =~ "A can now message B"
    assert Config.get_agent("A").can_message == ["default/B"]
    # Directed: B -> A was not created.
    assert Config.get_agent("B").can_message == []
  end

  test "from defaults to the calling agent" do
    ctx = %{agent: %Agent{name: "A"}}
    assert {:ok, _} = SetRoute.run(%{"to" => "B"}, ctx)
    assert Config.get_agent("A").can_message == ["default/B"]
  end

  test "deny removes the route" do
    Config.allow_message("A", "B")
    assert {:ok, msg} = SetRoute.run(%{"from" => "A", "to" => "B", "action" => "deny"}, %{})
    assert msg =~ "Removed route A -> B"
    assert Config.get_agent("A").can_message == []
  end

  test "rejects an unknown agent" do
    assert {:error, msg} = SetRoute.run(%{"from" => "A", "to" => "ghost"}, %{})
    assert msg =~ "Unknown agent: ghost"
  end
end
