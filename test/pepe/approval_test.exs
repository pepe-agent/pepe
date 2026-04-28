defmodule Pepe.ApprovalTest do
  use ExUnit.Case, async: false

  alias Pepe.Approval
  alias Pepe.Config
  alias Pepe.Agent.Workspace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_appr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Config.Agent{name: "helper", tools: ["write_file"]})
    :ok
  end

  defp write_call(path, content) do
    %{
      "id" => "t1",
      "function" => %{"name" => "write_file", "arguments" => Jason.encode!(%{"path" => path, "content" => content})}
    }
  end

  test "stage then list shows the pending write" do
    {:ok, id, _} = Approval.stage("helper", write_call("MEMORY.md", "a fact"))

    assert [%{"id" => ^id, "tool" => "write_file", "agent" => "helper"}] = Approval.list()
    assert Approval.count() == 1
  end

  test "approve applies the staged write to the agent workspace and clears it" do
    {:ok, id, _} = Approval.stage("helper", write_call("MEMORY.md", "remembered"))

    assert {:ok, _} = Approval.approve(id)
    assert File.read!(Path.join(Workspace.dir("helper"), "MEMORY.md")) == "remembered"
    assert Approval.list() == []
  end

  test "reject discards the staged write without applying it" do
    {:ok, id, _} = Approval.stage("helper", write_call("MEMORY.md", "should not land"))

    assert :ok = Approval.reject(id)
    refute File.exists?(Path.join(Workspace.dir("helper"), "MEMORY.md"))
    assert Approval.list() == []
  end

  test "approving or rejecting an unknown id is a clean error" do
    assert {:error, :not_found} = Approval.approve("nope")
    assert {:error, :not_found} = Approval.reject("nope")
  end
end
