defmodule Pepe.LearningTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Learning

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_learn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "timeline includes user skills and agent memory entries", %{home: home} do
    # A user skill
    File.mkdir_p!(Path.join(home, "skills"))
    File.write!(Path.join(home, "skills/read-pdf.md"), "Use when reading a PDF.\n\nsteps")

    # Agent memory
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "Fact one.\n\nFact two.")
    File.write!(Path.join(dir, "USER.md"), "The user is Jho.")

    nodes = Learning.timeline("zak")

    skills = Enum.filter(nodes, &(&1.kind == :skill))
    memory = Enum.filter(nodes, &(&1.kind == :memory))

    assert Enum.any?(skills, &(&1.title == "read-pdf" and &1.source == :user))
    # Built-in skills are picked up too.
    assert Enum.any?(skills, &(&1.source == :builtin))
    # MEMORY.md split into two entries + USER.md one entry.
    assert length(Enum.filter(memory, &(&1.source == :memory))) == 2
    assert Enum.any?(memory, &(&1.source == :user and &1.summary =~ "Jho"))
  end

  test "counts groups by kind", %{home: _home} do
    dir = Workspace.dir("zak")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "MEMORY.md"), "one")

    counts = Learning.counts("zak")
    assert counts.memory == 1
    assert counts.skill > 0
  end
end
