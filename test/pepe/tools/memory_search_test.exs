defmodule Pepe.Tools.MemorySearchTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Tools.MemorySearch

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_memsearch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp ctx(agent_name), do: %{agent: %{name: agent_name}}

  test "finds a matching entry across MEMORY.md and USER.md" do
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "Prefers dark roast coffee.\n\nDislikes cold calls.")
    File.write!(Path.join(dir, "USER.md"), "The user is Jho, based in Sao Paulo.")

    assert {:ok, out} = MemorySearch.run(%{"query" => "coffee"}, ctx("zak"))
    assert out =~ "Prefers dark roast coffee"
    assert out =~ "[MEMORY.md]"
    refute out =~ "Jho"
  end

  test "is case-insensitive" do
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "Uses ELIXIR at work.")

    assert {:ok, out} = MemorySearch.run(%{"query" => "elixir"}, ctx("zak"))
    assert out =~ "ELIXIR"
  end

  test "reports no matches instead of an empty string" do
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "Something unrelated.")

    assert {:ok, out} = MemorySearch.run(%{"query" => "xyzzy"}, ctx("zak"))
    assert out =~ "No matches"
  end

  test "works with no memory files at all yet" do
    assert {:ok, out} = MemorySearch.run(%{"query" => "anything"}, ctx("brand-new-agent"))
    assert out =~ "No matches"
  end

  test "respects a limit" do
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "match one.\n\nmatch two.\n\nmatch three.")

    assert {:ok, out} = MemorySearch.run(%{"query" => "match", "limit" => 1}, ctx("zak"))
    assert length(String.split(out, "\n\n")) == 1
  end

  test "requires a query" do
    assert {:error, msg} = MemorySearch.run(%{}, ctx("zak"))
    assert msg =~ "query"
  end

  test "requires a calling agent in context" do
    assert {:error, msg} = MemorySearch.run(%{"query" => "x"}, %{})
    assert msg =~ "no calling agent"
  end

  test "does not read another agent's memory" do
    dir_a = Workspace.dir("agent-a")
    File.mkdir_p!(dir_a)
    File.write!(Path.join(dir_a, "MEMORY.md"), "agent a's secret fact.")

    dir_b = Workspace.dir("agent-b")
    File.mkdir_p!(dir_b)
    File.write!(Path.join(dir_b, "MEMORY.md"), "agent b's unrelated fact.")

    assert {:ok, out} = MemorySearch.run(%{"query" => "secret"}, ctx("agent-b"))
    assert out =~ "No matches"
  end

  test "is registered as a builtin tool and always-safe" do
    assert Pepe.Tools.by_name()["memory_search"] == MemorySearch
    refute Pepe.Permissions.requires_approval?("memory_search")
  end
end
