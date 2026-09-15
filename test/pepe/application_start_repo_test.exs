defmodule Pepe.ApplicationStartRepoTest do
  @moduledoc """
  `Pepe.Application.start_repo/0` is the actual child-spec `:start` used in every real boot
  (see `repo_children/0`), but `repo_children/0` returns `[]` under `:test`, so nothing in
  the ordinary suite ever ran this function - every other test reaches `Pepe.Repo` only
  through `Pepe.RepoSetup.start!/0`, which calls `Pepe.Repo.start_link/1` and
  `Pepe.Repo.migrate!/1` directly instead. Exercised here, once, against a fresh unmigrated
  `PEPE_HOME`, so a regression in the actual boot path (wrong child spec `:start`, a start
  that returns before migrations run) has a test to fail.
  """
  use ExUnit.Case, async: false

  test "starts Pepe.Repo and runs schema migrations against a fresh PEPE_HOME" do
    home = Path.join(System.tmp_dir!(), "pepe_start_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    assert {:ok, pid} = Pepe.Application.start_repo()
    assert Process.alive?(pid)

    # A query against a table only the schema migrations create - proves start_repo/0
    # actually migrated before returning, not just started the connection pool.
    assert {:ok, _} = Pepe.Repo.query("SELECT COUNT(*) FROM insight_specs")

    Supervisor.stop(pid)
  end
end
