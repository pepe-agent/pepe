defmodule Pepe.MemoryTest do
  @moduledoc "The facade over the `memory` slot - `Pepe.Memory.Builtin` itself is exercised via `Pepe.Tools.MemorySearchTest`."
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_memfacade_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Pepe.Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "hi"})
    File.mkdir_p!(Workspace.dir("assistant"))
    File.write!(Path.join(Workspace.dir("assistant"), "MEMORY.md"), "The user prefers dark mode.\n\nThe deploy runs on Fridays.")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "search/3 finds a matching entry via the default occupant" do
    assert {:ok, [hit]} = Pepe.Memory.search("assistant", "dark mode")
    assert hit.file == "MEMORY.md"
    assert hit.entry =~ "dark mode"
  end

  test "search/3 with no matches returns an empty list, not an error" do
    assert {:ok, []} = Pepe.Memory.search("assistant", "something not in there")
  end

  test "search/3 matches words, not the whole query as one phrase, ranked by how many match" do
    File.write!(
      Path.join(Workspace.dir("assistant"), "MEMORY.md"),
      "Leads data lives in the Postgres of the Kaza app; password in the vault.\n\nThe deploy runs on Fridays."
    )

    assert {:ok, [hit]} = Pepe.Memory.search("assistant", "where is the postgres with the leads data?")
    assert hit.entry =~ "Postgres"
  end

  test "search/3 ignores case and accents in both directions" do
    File.write!(Path.join(Workspace.dir("assistant"), "MEMORY.md"), "A conexão com o Banco fica no cofre.")

    assert {:ok, [_]} = Pepe.Memory.search("assistant", "CONEXAO")
    assert {:ok, [_]} = Pepe.Memory.search("assistant", "conexão banco")
  end

  test "search/3 also reads other knowledge notes the agent keeps" do
    File.write!(Path.join(Workspace.dir("assistant"), "databases.md"), "Kaza leads: postgres at the vault item kaza-ro.")

    assert {:ok, [hit]} = Pepe.Memory.search("assistant", "kaza leads")
    assert hit.file == "databases.md"
  end

  test "search/3 also reads the daily logs" do
    File.mkdir_p!(Path.join(Workspace.dir("assistant"), "memory"))
    File.write!(Path.join(Workspace.dir("assistant"), "memory/2026-10-13.md"), "Regenerated the Instagram carousel with the dark template.")

    assert {:ok, [hit]} = Pepe.Memory.search("assistant", "instagram carousel template")
    assert hit.file == "memory/2026-10-13.md"
  end

  test "reindex/1 no-ops for the builtin, which has nothing to index" do
    assert Pepe.Memory.reindex("assistant") == :ok
  end

  test "status/0 reports the builtin as the occupant with keyword-only capability" do
    assert %{occupant: "builtin", capabilities: %{keyword: true, vector: false}} = Pepe.Memory.status()
  end
end
