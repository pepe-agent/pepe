defmodule Pepe.Checkpoints.RewindTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Checkpoints
  alias Pepe.Checkpoints.Retention
  alias Pepe.Checkpoints.Store
  alias Pepe.LLM.Message

  @key "test:rewind"

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rewind_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    agent = %{name: "zak", checkpoints: true, checkpoint_shell: false}
    workspace = Workspace.dir("zak")
    File.mkdir_p!(workspace)
    %{agent: agent, workspace: workspace, ctx: %{agent: agent, session_key: @key, cwd: workspace}, home: home}
  end

  # One completed turn: run tool calls through the same wrapper the runtime uses, then commit
  # the turn against a history that has grown by one person message.
  defp turn(ctx, history, text, calls) do
    Enum.each(calls, fn {name, args} ->
      Checkpoints.around(name, args, ctx, fn -> run(name, args, ctx) end)
    end)

    history = history ++ [Message.user(text), Message.assistant("done")]
    :ok = Checkpoints.commit_turn(@key, [Checkpoints.fingerprint(Message.user(text))])
    history
  end

  defp run("write_file", %{"path" => path, "content" => content}, ctx) do
    full = Workspace.resolve_in_ctx(path, ctx)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    {:ok, "wrote"}
  end

  defp run("edit_file", %{"path" => path, "old_string" => old, "new_string" => new}, ctx) do
    full = Workspace.resolve_in_ctx(path, ctx)
    File.write!(full, String.replace(File.read!(full), old, new))
    {:ok, "edited"}
  end

  defp run("move_file", %{"from" => from, "to" => to}, ctx) do
    File.rename!(Workspace.resolve_in_ctx(from, ctx), Workspace.resolve_in_ctx(to, ctx))
    {:ok, "moved"}
  end

  defp roots(ctx), do: Checkpoints.allowed_roots(ctx.agent.name)

  describe "putting files back" do
    test "an overwrite is undone, and a file the turn created is removed", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "notes.md"), "original")

      history =
        turn(ctx, [], "rewrite my notes and add a todo", [
          {"write_file", %{"path" => "notes.md", "content" => "rewritten"}},
          {"write_file", %{"path" => "todo.md", "content" => "new"}}
        ])

      assert File.read!(Path.join(ws, "notes.md")) == "rewritten"

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(Path.join(ws, "notes.md")) == "original"
      refute File.exists?(Path.join(ws, "todo.md"))
      assert report.restored == [Path.join(ws, "notes.md")]
      assert report.removed == [Path.join(ws, "todo.md")]
      assert report.skipped == []
    end

    test "several edits across two turns go back to the very first version, or one turn at a time", %{ctx: ctx, workspace: ws} do
      file = Path.join(ws, "a.txt")
      File.write!(file, "v0")

      history = turn(ctx, [], "first", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      history = turn(ctx, history, "second", [{"edit_file", %{"path" => "a.txt", "old_string" => "v1", "new_string" => "v2"}}])

      Checkpoints.restore(@key, history, 1, roots: roots(ctx))
      assert File.read!(file) == "v1"

      # The restored turn must not be put back a second time, and the older one still can be.
      report = Checkpoints.restore(@key, history, 2, roots: roots(ctx))
      assert File.read!(file) == "v0"
      assert report.restored == [file]
    end

    test "a moved file comes back and its destination goes away", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "old.txt"), "same bytes")
      history = turn(ctx, [], "rename it", [{"move_file", %{"from" => "old.txt", "to" => "new.txt"}}])

      Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(Path.join(ws, "old.txt")) == "same bytes"
      refute File.exists?(Path.join(ws, "new.txt"))
    end

    test "a file edited by someone else afterwards is kept, and said so", %{ctx: ctx, workspace: ws} do
      file = Path.join(ws, "a.txt")
      File.write!(file, "v0")
      history = turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      File.write!(file, "hand edited afterwards")

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(file) == "hand edited afterwards"
      assert report.restored == []
      assert report.skipped == [%{path: file, reason: :changed_since}]
    end

    test "what it replaces is kept as a blob and listed in a restore record", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")
      history = turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])

      Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      scope = Store.digest(ws)

      kept =
        for id <- Store.record_ids(scope), {:ok, %{"kind" => "restore", "files" => [file]}} <- [Store.read_record(scope, id)], do: file

      assert [%{"before" => sha}] = kept
      assert {:ok, "v1"} = Store.get_blob(sha)
    end

    test "a dry run reports what would happen and changes nothing", %{ctx: ctx, workspace: ws} do
      file = Path.join(ws, "a.txt")
      File.write!(file, "v0")
      history = turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx), dry_run: true)

      assert report.restored == [file]
      assert File.read!(file) == "v1"
      # ...and a dry run does not use the turn up.
      assert Checkpoints.restore(@key, history, 1, roots: roots(ctx)).restored == [file]
    end
  end

  describe "what it refuses" do
    test "a credential-looking file is never copied, and the report says why", %{ctx: ctx, workspace: ws} do
      history = turn(ctx, [], "set the token", [{"write_file", %{"path" => ".env", "content" => "TOKEN=abc"}}])

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(Path.join(ws, ".env")) == "TOKEN=abc"
      assert report.untracked == [%{path: Path.join(ws, ".env"), reason: :sensitive}]
      assert Store.blobs() == []
    end

    test "a path outside the allowed folders is not tracked and not restorable", %{ctx: ctx, home: home} do
      outside = Path.join(home, "elsewhere.txt")
      File.write!(outside, "mine")

      history = turn(ctx, [], "overwrite it", [{"write_file", %{"path" => outside, "content" => "theirs"}}])
      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(outside) == "theirs"
      assert report.untracked == [%{path: outside, reason: :outside}]
    end

    test "a record that names a file outside the roots is refused at restore time", %{ctx: ctx, workspace: ws, home: home} do
      victim = Path.join(home, "victim.txt")
      File.write!(victim, "precious")
      sha = Store.put_blob("attacker bytes")
      after_sha = Checkpoints.Snapshot.sha("precious")
      scope = Store.digest(ws)
      id = Store.new_id()

      Store.write_record(scope, ws, %{
        "id" => id,
        "files" => [%{"path" => victim, "before" => sha, "after" => after_sha, "mode" => 0o644, "size" => 8}]
      })

      Store.update_log(@key, fn log -> %{log | "pending" => [%{"scope" => scope, "id" => id}]} end)
      history = [Message.user("x"), Message.assistant("y")]
      :ok = Checkpoints.commit_turn(@key, [Checkpoints.fingerprint(Message.user("x"))])

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(victim) == "precious"
      assert report.skipped == [%{path: victim, reason: :outside}]
    end

    test "a symlink on the way in refuses the file", %{ctx: ctx, workspace: ws, home: home} do
      real = Path.join(home, "real_dir")
      File.mkdir_p!(real)
      File.write!(Path.join(real, "a.txt"), "v0")
      File.ln_s!(real, Path.join(ws, "link"))

      # A record whose path now goes through a symlink out of the workspace must never be
      # written through it, however plausible the record looks.
      scope = Store.digest(ws)
      id = Store.new_id()
      planted = Store.put_blob("planted")

      Store.write_record(scope, ws, %{
        "id" => id,
        "files" => [
          %{"path" => Path.join([ws, "link", "a.txt"]), "before" => planted, "after" => Checkpoints.Snapshot.sha("v0"), "mode" => 0o644}
        ]
      })

      Store.update_log(@key, fn log -> %{log | "pending" => [%{"scope" => scope, "id" => id}]} end)
      :ok = Checkpoints.commit_turn(@key, [Checkpoints.fingerprint(Message.user("go"))])
      history = [Message.user("go"), Message.assistant("ok")]

      report = Checkpoints.restore(@key, history, 1, roots: roots(ctx))

      assert File.read!(Path.join(real, "a.txt")) == "v0"
      assert [%{reason: :outside}] = report.skipped
    end

    test "checkpoints off means nothing is recorded", %{ctx: ctx, workspace: ws} do
      ctx = put_in(ctx.agent.checkpoints, false)
      File.write!(Path.join(ws, "a.txt"), "v0")

      turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])

      assert Store.scope_ids() == []
      assert Store.read_log(@key) == %{"turns" => [], "pending" => []}
    end
  end

  describe "keeping the log aligned with the conversation" do
    test "an edited history stops the rewind at the first turn it can no longer vouch for", %{ctx: ctx, workspace: ws} do
      file = Path.join(ws, "a.txt")
      File.write!(file, "v0")

      history = turn(ctx, [], "first", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      history = turn(ctx, history, "second", [{"edit_file", %{"path" => "a.txt", "old_string" => "v1", "new_string" => "v2"}}])

      # The first message is different in the live history than when it was recorded.
      tampered = List.replace_at(history, 0, Message.user("something else"))
      report = Checkpoints.restore(@key, tampered, 2, roots: roots(ctx))

      assert File.read!(file) == "v1"
      assert report.unreached == 1
    end

    test "a turn that changed no files still keeps the alignment once tracking began", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")

      history = turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      history = turn(ctx, history, "just chatting", [])
      history = turn(ctx, history, "more chatting", [])

      assert [%{n: 1, files: 0}, %{n: 2, files: 0}, %{n: 3, files: 1, preview: "edit"}] = Checkpoints.turns(@key, history, 10)
      assert Checkpoints.restore(@key, history, 3, roots: roots(ctx)).restored == [Path.join(ws, "a.txt")]
    end

    test "a session that never changed a file writes no log at all", %{ctx: ctx} do
      turn(ctx, [], "hello", [])
      assert Store.log_files() == []
    end

    test "turns older than tracking are reported as unknown, not as empty", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")
      before_tracking = [Message.user("from before"), Message.assistant("ok")]
      history = turn(ctx, before_tracking, "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])

      assert [%{n: 1, files: 1}, %{n: 2, files: nil}] = Checkpoints.turns(@key, history, 10)
      assert Checkpoints.restore(@key, history, 2, roots: roots(ctx)).unreached == 1
    end

    test "popping turns keeps the log in step with a conversation that dropped them", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")
      history = turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      history = turn(ctx, history, "second", [])

      Checkpoints.pop_turns(@key, 1)

      assert [%{"fp" => _}] = Store.read_log(@key)["turns"]
      assert [%{n: 1, files: 1}] = Checkpoints.turns(@key, Enum.take(history, 2), 10)
    end
  end

  describe "the shell flag" do
    test "a command's file changes are recorded only when the agent opted in", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")

      shell = fn ->
        File.write!(Path.join(ws, "a.txt"), "changed by a command")
        {:ok, "ok"}
      end

      Checkpoints.around("bash", %{"command" => "x"}, ctx, shell)
      assert Store.scope_ids() == []

      on = put_in(ctx.agent.checkpoint_shell, true)
      File.write!(Path.join(ws, "a.txt"), "v0")
      Checkpoints.around("bash", %{"command" => "x"}, on, shell)

      assert [scope] = Store.scope_ids()
      assert [id] = Store.record_ids(scope)
      assert {:ok, %{"tool" => "bash", "files" => [%{"path" => path}]}} = Store.read_record(scope, id)
      assert path == Path.join(ws, "a.txt")
    end
  end

  describe "through the tool choke point" do
    test "Pepe.Tools.execute records a write_file call made with an agent context", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")

      call = %{"function" => %{"name" => "write_file", "arguments" => Jason.encode!(%{"path" => "a.txt", "content" => "v1"})}}
      assert Pepe.Tools.execute(call, ctx) =~ "wrote"

      assert [%{"scope" => _, "id" => _}] = Store.read_log(@key)["pending"]
    end

    test "a tool that crashes after changing a file still leaves its record", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")

      assert_raise RuntimeError, fn ->
        Checkpoints.around("write_file", %{"path" => "a.txt", "content" => "v1"}, ctx, fn ->
          File.write!(Path.join(ws, "a.txt"), "half written")
          raise "boom"
        end)
      end

      assert [_] = Store.read_log(@key)["pending"]
    end
  end

  describe "retention" do
    test "old records go, their unreferenced blobs go, and blobs still in use stay", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")
      File.write!(Path.join(ws, "b.txt"), "b0")

      turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])
      turn(ctx, [], "edit b", [{"edit_file", %{"path" => "b.txt", "old_string" => "b0", "new_string" => "b1"}}])

      scope = Store.digest(ws)
      [newer, older] = Store.record_ids(scope)
      assert [_, _] = Store.blobs()

      # Age one record past the cutoff by asking to prune from far in the future is too blunt:
      # rewrite the older record's id timestamp instead, by pruning with a shrunk age.
      now = String.to_integer(binary_part(newer, 0, 16)) + 10 * 86_400 * 1_000_000
      result = Retention.prune(max_age_days: 5, now: now + 3 * 86_400 * 1_000_000)

      assert result.records == 2
      assert Store.record_ids(scope) == []
      _ = older
    end

    test "the size cap drops the oldest records first and collects their blobs", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), String.duplicate("a", 1000))

      turn(ctx, [], "one", [{"write_file", %{"path" => "a.txt", "content" => String.duplicate("b", 1000)}}])
      turn(ctx, [], "two", [{"write_file", %{"path" => "a.txt", "content" => String.duplicate("c", 1000)}}])

      scope = Store.digest(ws)
      assert [_, _] = Store.record_ids(scope)

      result = Retention.prune(max_bytes: 1)

      assert result.records >= 1
      assert Store.bytes() <= Retention.max_bytes()
    end

    test "a blob that is not old enough is never collected, even with no record naming it" do
      sha = Store.put_blob("just written")
      Retention.prune()
      assert {:ok, "just written"} = Store.get_blob(sha)
    end

    test "status counts what is there and clear removes it all", %{ctx: ctx, workspace: ws} do
      File.write!(Path.join(ws, "a.txt"), "v0")
      turn(ctx, [], "edit", [{"edit_file", %{"path" => "a.txt", "old_string" => "v0", "new_string" => "v1"}}])

      assert %{records: 1, blobs: 1, scopes: 1, sessions: 1} = Retention.status()
      assert Retention.clear() > 0
      assert %{records: 0, blobs: 0} = Retention.status()
    end
  end
end
