defmodule Pepe.Checkpoints.SafetyTest do
  @moduledoc """
  Regression tests for an independent safety review of the checkpoint store: a run that
  errors or is stopped must not let its file changes roll onto a later, unrelated turn; a
  blob still in use must survive garbage collection; a snapshot rooted at $HOME must never
  touch Pepe's own config; `sensitive?/1` must catch more than a handful of filenames; a
  partially-restored turn must stay retryable; and a write racing a restore on the same
  root must not corrupt the file.
  """
  use ExUnit.Case, async: false

  alias Pepe.Checkpoints
  alias Pepe.Checkpoints.Retention
  alias Pepe.Checkpoints.Snapshot
  alias Pepe.Checkpoints.Store

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_checkpoints_safety_#{System.unique_integer([:positive])}")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home, workspace: workspace}
  end

  describe "discard_pending/1" do
    test "a run that never commits does not let its file changes roll onto a later turn", %{workspace: workspace} do
      key = "sess-#{System.unique_integer([:positive])}"
      target = Path.join(workspace, "a.txt")
      File.write!(target, "v0")

      ctx = %{agent: %{name: "a"}, cwd_override: workspace, session_key: key}

      # Turn 1: a real, successfully committed turn - so the log is no longer empty (an
      # empty log's commit_turn/2 is itself a no-op, which would hide the bug this proves).
      Checkpoints.around("write_file", %{"path" => target}, ctx, fn ->
        File.write!(target, "v1")
        {:ok, "done"}
      end)

      Checkpoints.commit_turn(key, [Checkpoints.fingerprint(%{"content" => "first"})])

      # Turn 2 changes a file, but the run it belonged to errors/is stopped - it never
      # reaches commit_turn/2.
      Checkpoints.around("write_file", %{"path" => target}, ctx, fn ->
        File.write!(target, "v2")
        {:ok, "done"}
      end)

      assert Store.read_log(key)["pending"] != []
      Checkpoints.discard_pending(key)
      assert Store.read_log(key)["pending"] == []

      # Turn 3 is unrelated and actually committed - it must not inherit turn 2's refs.
      Checkpoints.commit_turn(key, [Checkpoints.fingerprint(%{"content" => "third"})])

      messages = [%{"role" => "user", "content" => "first"}, %{"role" => "user", "content" => "third"}]
      assert [%{n: 1, files: 0}, %{n: 2, files: 1}] = Checkpoints.turns(key, messages, 2)
    end
  end

  describe "Store.put_blob/1" do
    test "bumps the mtime of a blob that already exists instead of leaving it looking stale" do
      sha = Store.put_blob("same content, first write")
      path = Path.join([Store.root(), "blobs", binary_part(sha, 0, 2), sha])

      old = System.os_time(:second) - 100_000
      File.touch!(path, old)
      assert {:ok, %File.Stat{mtime: ^old}} = File.stat(path, time: :posix)

      assert ^sha = Store.put_blob("same content, first write")

      assert {:ok, %File.Stat{mtime: mtime}} = File.stat(path, time: :posix)
      assert mtime > old
    end
  end

  describe "Retention size-cap shrinking" do
    test "does not collect a blob still inside its grace window", %{workspace: workspace} do
      scope = Store.digest(workspace)

      for i <- 1..5 do
        sha = Store.put_blob(String.duplicate("x", 200))
        id = Store.new_id()

        record = %{
          "id" => id,
          "at" => 0,
          "tool" => "write_file",
          "partial" => false,
          "files" => [%{"path" => "f#{i}", "before" => sha, "after" => nil, "mode" => 0o644, "size" => 200}],
          "skipped" => []
        }

        :ok = Store.write_record(scope, workspace, record)
      end

      # Written independently, so nothing references it yet - the exact shape of the race a
      # `Checkpoints.record/3` in progress leaves for a split second (blob before record).
      recent_sha = Store.put_blob("recent, unreferenced, written moments ago")

      # max_age_days huge so only the size-cap path runs, never the age-based one.
      Retention.prune(max_age_days: 9999, max_bytes: 1)

      assert {:ok, _} = Store.get_blob(recent_sha)
    end
  end

  describe "Snapshot.sensitive?/1" do
    test "catches the extended credential and secret patterns" do
      for name <- ~w(.envrc credentials.json .git-credentials .htpasswd .pgpass .my.cnf
                     secrets.yaml service-account-123.json token.json key.p8 backup.gpg
                     signature.asc terraform.tfstate client.ovpn .env-local) do
        assert Snapshot.sensitive?("/x/#{name}"), "expected #{name} to be sensitive"
      end
    end

    test "catches anything under a credential directory regardless of filename" do
      for dir <- ~w(.ssh .aws .gnupg .kube .docker) do
        assert Snapshot.sensitive?("/home/me/#{dir}/anything.txt")
      end

      refute Snapshot.sensitive?("/home/me/project/anything.txt")
    end
  end

  describe "Snapshot.take/2 with a home-rooted walk" do
    test "never tracks Pepe's own config even as the walked root itself", %{home: home} do
      config = Path.join(home, "config.json")
      File.write!(config, "before")

      ctx = %{agent: %{checkpoint_shell: true}, cwd_override: home, session_key: "sess-home"}

      Checkpoints.around("bash", %{}, ctx, fn ->
        File.write!(config, "after")
        {:ok, "done"}
      end)

      assert Store.record_ids(Store.digest(Path.expand(home))) == []
    end

    test "stops recursing into subdirectories once the file cap is already hit" do
      dir = Path.join(System.tmp_dir!(), "pepe_snapshot_cap_#{System.unique_integer([:positive])}")
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      for i <- 1..5, do: File.write!(Path.join(dir, "f#{i}.txt"), "x")
      for i <- 1..5, do: File.write!(Path.join(sub, "g#{i}.txt"), "x")
      on_exit(fn -> File.rm_rf(dir) end)

      snapshot = Snapshot.take([dir], max_files: 3)

      assert snapshot.partial?
      assert map_size(snapshot.files) <= 3
    end
  end

  describe "a partial restore" do
    test "is not marked fully restored, so a fixed retry can still be reached", %{workspace: workspace} do
      key = "sess-#{System.unique_integer([:positive])}"
      target = Path.join(workspace, "locked.txt")
      File.write!(target, "before")
      readable = Path.join(workspace, "readable.txt")
      File.write!(readable, "before")

      ctx = %{agent: %{name: "a"}, cwd_override: workspace, session_key: key}

      Checkpoints.around("write_file", %{"path" => readable}, ctx, fn ->
        File.write!(readable, "after")
        {:ok, "done"}
      end)

      Checkpoints.around("write_file", %{"path" => target}, ctx, fn ->
        File.write!(target, "after")
        {:ok, "done"}
      end)

      Checkpoints.commit_turn(key, [Checkpoints.fingerprint(%{"content" => "go"})])

      # Change readable.txt after the fact, so its restore is skipped as "changed since" -
      # the turn is only partially restorable.
      File.write!(readable, "changed by hand since")

      messages = [%{"role" => "user", "content" => "go"}]
      report = Checkpoints.restore(key, messages, 1, roots: [workspace])

      assert report.skipped != []
      assert File.read!(target) == "before"

      # readable.txt is put back to what the tool actually left it as (undoing the
      # person's own manual edit, the fix a :changed_since skip calls for), and the same
      # restore is asked for again. Before this fix, the whole turn was already marked
      # "restored" by the first call above (report.skipped != [] notwithstanding), so this
      # second attempt would have reported :already and never touched readable.txt again.
      File.write!(readable, "after")
      report2 = Checkpoints.restore(key, messages, 1, roots: [workspace])

      assert report2.already == 0
      assert readable in report2.restored
      assert File.read!(readable) == "before"
    end
  end

  describe "concurrent access to the same root" do
    test "two tool calls on the same scope run one at a time, never interleaved" do
      dir = Path.join(System.tmp_dir!(), "pepe_lock_ws_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, log} = Agent.start_link(fn -> [] end)
      ctx = %{agent: %{name: "a"}, cwd_override: dir, session_key: "lock-sess"}

      t1 =
        Task.async(fn ->
          Checkpoints.around("write_file", %{"path" => Path.join(dir, "f1.txt")}, ctx, fn ->
            Agent.update(log, &[:enter1 | &1])
            Process.sleep(150)
            File.write!(Path.join(dir, "f1.txt"), "one")
            Agent.update(log, &[:exit1 | &1])
            {:ok, "done"}
          end)
        end)

      Process.sleep(30)

      t2 =
        Task.async(fn ->
          Checkpoints.around("write_file", %{"path" => Path.join(dir, "f2.txt")}, ctx, fn ->
            Agent.update(log, &[:enter2 | &1])
            File.write!(Path.join(dir, "f2.txt"), "two")
            Agent.update(log, &[:exit2 | &1])
            {:ok, "done"}
          end)
        end)

      Task.await(t1, 5000)
      Task.await(t2, 5000)

      assert Agent.get(log, &Enum.reverse/1) == [:enter1, :exit1, :enter2, :exit2]
    end
  end
end
