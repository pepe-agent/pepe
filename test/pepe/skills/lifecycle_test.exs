defmodule Pepe.Skills.LifecycleTest do
  use ExUnit.Case, async: false

  alias Pepe.Skills.Backup
  alias Pepe.Skills.Ledger
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stats

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_skill_lifecycle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  test "adopt, pin, archive and restore retain ownership metadata and an audit trail", %{home: home} do
    file = Path.join([home, "skills", "draft.md"])
    File.write!(file, "Use when drafting.\n")

    Stats.adopt("draft", "user:cli")
    Stats.pin("draft", true)
    assert Ownership.origin("draft") == :agent
    refute Ownership.background_writable?("draft")

    assert {:ok, archive_dir} = Lifecycle.archive("draft", "user:cli")
    refute File.exists?(file)
    assert File.exists?(Path.join(archive_dir, "draft.md"))
    assert Stats.get("draft").state == "archived"

    assert {:ok, ^file} = Lifecycle.restore("draft", "user:cli")
    assert File.read!(file) == "Use when drafting.\n"
    assert Stats.get("draft").state == "active"
    assert Enum.map(Ledger.recent(10, "draft"), & &1.action) == ["restore", "archive"]
  end

  test "backup rollback restores the complete skills tree", %{home: home} do
    file = Path.join([home, "skills", "one.md"])
    File.write!(file, "version one")
    assert {:ok, id} = Backup.create("test", "user:cli")

    File.write!(file, "version two")
    File.write!(Path.join([home, "skills", "extra.md"]), "extra")

    assert {:ok, ^id} = Backup.rollback(id, "user:cli")
    assert File.read!(file) == "version one"
    refute File.exists?(Path.join([home, "skills", "extra.md"]))
  end
end
