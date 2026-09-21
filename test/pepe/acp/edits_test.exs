defmodule Pepe.ACP.EditsTest do
  @moduledoc """
  `Pepe.ACP.Edits.mode_decision/5` is the one place a permission gate is answered without
  a human, so what it must NEVER answer for is pinned here as carefully as what it may.

  The directories are laid out so "inside the project", "the temp dir" and "elsewhere" are
  three different places: TMPDIR is pointed at its own folder, and the project sits beside it.
  """
  use ExUnit.Case, async: false

  alias Pepe.ACP.Edits

  setup do
    root = Path.join(System.tmp_dir!(), "pepe_acp_edits_#{System.unique_integer([:positive])}")
    project = Path.join(root, "project")
    tmp = Path.join(root, "tmp")
    outside = Path.join(root, "outside")
    home = Path.join(root, "pepe_home")
    Enum.each([project, tmp, outside, home], &File.mkdir_p!/1)

    prev = for k <- ~w(TMPDIR PEPE_HOME), do: {k, System.get_env(k)}
    System.put_env("TMPDIR", tmp)
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf(root)
    end)

    {:ok, root: root, project: project, tmp: tmp, outside: outside, home: home}
  end

  defp write_args(path), do: %{"path" => path, "content" => "x"}

  describe "mode_decision/5 in the default mode" do
    test "asks about everything, edits included", %{project: project} do
      for tool <- ["write_file", "edit_file", "move_file", "bash", "read_file"] do
        assert Edits.mode_decision("default", tool, write_args("a.txt"), %{}, project) == :ask
      end
    end

    test "an unknown mode is never read as permission", %{project: project} do
      assert Edits.mode_decision("yolo", "write_file", write_args("a.txt"), %{}, project) == :ask
      assert Edits.mode_decision(nil, "write_file", write_args("a.txt"), %{}, project) == :ask
    end
  end

  describe "mode_decision/5 under accept_edits" do
    test "allows a file inside the project the editor opened", %{project: project} do
      assert Edits.mode_decision("accept_edits", "write_file", write_args("lib/a.ex"), %{}, project) == :once
      assert Edits.mode_decision("accept_edits", "write_file", write_args(Path.join(project, "lib/a.ex")), %{}, project) == :once
    end

    test "allows the temp directory", %{tmp: tmp, project: project} do
      assert Edits.mode_decision("accept_edits", "write_file", write_args(Path.join(tmp, "scratch.txt")), %{}, project) == :once
    end

    test "asks about anywhere else", %{outside: outside, project: project} do
      assert Edits.mode_decision("accept_edits", "write_file", write_args(Path.join(outside, "a.txt")), %{}, project) == :ask
    end

    test "asks when there is no project to be inside of", %{outside: outside} do
      assert Edits.mode_decision("accept_edits", "write_file", write_args(Path.join(outside, "a.txt")), %{}, nil) == :ask
    end

    test "a `..` that climbs out of the project is judged where it lands", %{project: project} do
      assert Edits.mode_decision("accept_edits", "write_file", write_args("../outside/a.txt"), %{}, project) == :ask
    end

    test "a sibling directory that merely shares the project's name as a prefix is not inside it", %{root: root, project: project} do
      sibling = Path.join(root, "project-evil")
      File.mkdir_p!(sibling)
      assert Edits.mode_decision("accept_edits", "write_file", write_args(Path.join(sibling, "a.txt")), %{}, project) == :ask
    end

    test "edit_file is judged by its path, and a JSON string of arguments is read the same way", %{project: project} do
      args = Jason.encode!(%{"path" => "a.txt", "old_string" => "a", "new_string" => "b"})
      assert Edits.mode_decision("accept_edits", "edit_file", args, %{}, project) == :once
    end

    test "move_file needs BOTH ends inside", %{project: project, outside: outside} do
      inside = %{"from" => "a.txt", "to" => "b.txt"}
      leaving = %{"from" => "a.txt", "to" => Path.join(outside, "b.txt")}

      assert Edits.mode_decision("accept_edits", "move_file", inside, %{}, project) == :once
      assert Edits.mode_decision("accept_edits", "move_file", leaving, %{}, project) == :ask
    end

    test "arguments that name no path leave nothing to allow", %{project: project} do
      assert Edits.mode_decision("accept_edits", "write_file", %{"content" => "x"}, %{}, project) == :ask
      assert Edits.mode_decision("accept_edits", "write_file", "not json", %{}, project) == :ask
      assert Edits.mode_decision("accept_edits", "write_file", %{"path" => 5}, %{}, project) == :ask
    end

    test "never answers for a command, only for file edits", %{project: project} do
      assert Edits.mode_decision("accept_edits", "bash", %{"command" => "rm -rf ."}, %{}, project) == :ask
      assert Edits.mode_decision("accept_edits", "run_script", %{}, %{}, project) == :ask
    end
  end

  describe "mode_decision/5 under dont_ask" do
    test "allows an edit anywhere that is not sensitive", %{outside: outside, project: project} do
      assert Edits.mode_decision("dont_ask", "write_file", write_args(Path.join(outside, "a.txt")), %{}, project) == :once
      assert Edits.mode_decision("dont_ask", "write_file", write_args(Path.join(outside, "a.txt")), %{}, nil) == :once
    end
  end

  describe "what no mode ever answers for" do
    test "a run that has taken in outside content", %{project: project} do
      for mode <- ["accept_edits", "dont_ask"] do
        assert Edits.mode_decision(mode, "write_file", write_args("a.txt"), %{tainted: true}, project) == :ask
      end
    end

    test "a call a policy plugin escalated", %{project: project} do
      for mode <- ["accept_edits", "dont_ask"] do
        assert Edits.mode_decision(mode, "write_file", write_args("a.txt"), %{policy_reason: "needs a person"}, project) == :ask
      end
    end

    test "credentials, keys, .git, and dotenv files", %{project: project} do
      sensitive = [
        ".git/config",
        ".git/hooks/pre-commit",
        ".ssh/authorized_keys",
        ".aws/credentials",
        "deploy/id_rsa",
        "id_ed25519",
        ".env",
        ".env.production",
        "certs/server.pem",
        "signing.key",
        ".npmrc",
        ".netrc",
        "credentials"
      ]

      for mode <- ["accept_edits", "dont_ask"], path <- sensitive do
        assert Edits.mode_decision(mode, "write_file", write_args(path), %{}, project) == :ask,
               "#{mode} must ask about #{path}"
      end
    end

    test "Pepe's own home, wherever PEPE_HOME points", %{home: home, project: project} do
      config = Path.join(home, "config.json")

      for mode <- ["accept_edits", "dont_ask"] do
        assert Edits.mode_decision(mode, "write_file", write_args(config), %{}, project) == :ask
      end
    end

    test "a sensitive destination on either end of a move", %{project: project} do
      move = %{"from" => "a.txt", "to" => ".git/HEAD"}

      for mode <- ["accept_edits", "dont_ask"] do
        assert Edits.mode_decision(mode, "move_file", move, %{}, project) == :ask
      end
    end
  end

  describe "symlinks are judged by where they lead" do
    test "a link inside the project that points out of it is not inside the project", %{project: project, outside: outside} do
      link = Path.join(project, "escape")
      :ok = File.ln_s(outside, link)

      assert Edits.mode_decision("accept_edits", "write_file", write_args("escape/a.txt"), %{}, project) == :ask
      # dont_ask has no boundary, so the same path is fine there: the link is only followed, not banned.
      assert Edits.mode_decision("dont_ask", "write_file", write_args("escape/a.txt"), %{}, project) == :once
    end

    test "a link that points at a sensitive place is sensitive even under dont_ask", %{project: project, outside: outside} do
      ssh = Path.join(outside, ".ssh")
      File.mkdir_p!(ssh)
      :ok = File.ln_s(ssh, Path.join(project, "innocent"))

      for mode <- ["accept_edits", "dont_ask"] do
        assert Edits.mode_decision(mode, "write_file", write_args("innocent/authorized_keys"), %{}, project) == :ask
      end
    end

    test "a link that stays inside the project changes nothing", %{project: project} do
      File.mkdir_p!(Path.join(project, "real"))
      :ok = File.ln_s(Path.join(project, "real"), Path.join(project, "alias"))

      assert Edits.mode_decision("accept_edits", "write_file", write_args("alias/a.txt"), %{}, project) == :once
    end
  end

  describe "real_path/1" do
    test "collapses `..` and leaves a path that does not exist yet as written", %{project: project} do
      real = Edits.real_path(Path.join(project, "a/../b/new.txt"))
      assert real == Edits.real_path(project) <> "/b/new.txt"
    end

    test "follows a chain of links", %{root: root} do
      target = Path.join(root, "target")
      File.mkdir_p!(target)
      :ok = File.ln_s(target, Path.join(root, "one"))
      :ok = File.ln_s(Path.join(root, "one"), Path.join(root, "two"))

      assert Edits.real_path(Path.join(root, "two")) == Edits.real_path(target)
    end

    test "resolves a relative link against the directory that holds it", %{root: root} do
      File.mkdir_p!(Path.join(root, "a/deep"))
      :ok = File.ln_s("deep", Path.join(root, "a/short"))

      assert Edits.real_path(Path.join(root, "a/short/file")) == Edits.real_path(Path.join(root, "a/deep")) <> "/file"
    end

    test "a link loop ends instead of spinning", %{root: root} do
      :ok = File.ln_s(Path.join(root, "b"), Path.join(root, "a"))
      :ok = File.ln_s(Path.join(root, "a"), Path.join(root, "b"))

      assert Edits.real_path(Path.join(root, "a")) == "/"
    end
  end

  describe "proposal/3" do
    test "a write over an existing file carries the file as it is and as it will be", %{project: project} do
      File.write!(Path.join(project, "a.txt"), "old")

      assert %{path: path, old: "old", new: "new"} = Edits.proposal("write_file", %{"path" => "a.txt", "content" => "new"}, project)
      assert path == Path.join(project, "a.txt")
    end

    test "a write that creates a file has no old text", %{project: project} do
      assert %{old: nil, new: "new"} = Edits.proposal("write_file", %{"path" => "fresh.txt", "content" => "new"}, project)
    end

    test "an edit that would match exactly once shows the replaced file", %{project: project} do
      File.write!(Path.join(project, "a.txt"), "hello world")
      args = %{"path" => "a.txt", "old_string" => "world", "new_string" => "there"}

      assert %{old: "hello world", new: "hello there"} = Edits.proposal("edit_file", args, project)
    end

    test "gives up quietly when the edit would not match exactly once", %{project: project} do
      File.write!(Path.join(project, "a.txt"), "x x")

      assert Edits.proposal("edit_file", %{"path" => "a.txt", "old_string" => "x", "new_string" => "y"}, project) == nil
      assert Edits.proposal("edit_file", %{"path" => "a.txt", "old_string" => "absent", "new_string" => "y"}, project) == nil
      assert Edits.proposal("edit_file", %{"path" => "missing.txt", "old_string" => "a", "new_string" => "b"}, project) == nil
    end

    test "gives up on a file that is not text, a directory, and a change too big to ship", %{project: project} do
      File.write!(Path.join(project, "bin.dat"), <<255, 254, 0, 1>>)
      File.mkdir_p!(Path.join(project, "dir"))

      assert Edits.proposal("write_file", %{"path" => "bin.dat", "content" => "x"}, project) == nil
      assert Edits.proposal("write_file", %{"path" => "dir", "content" => "x"}, project) == nil
      assert Edits.proposal("write_file", %{"path" => "big.txt", "content" => String.duplicate("a", 200_001)}, project) == nil
    end

    test "has nothing to say about other tools or malformed arguments", %{project: project} do
      assert Edits.proposal("bash", %{"command" => "ls"}, project) == nil
      assert Edits.proposal("write_file", %{"path" => "a.txt"}, project) == nil
    end

    test "diff_content/1 is an ACP diff block", %{project: project} do
      proposal = Edits.proposal("write_file", %{"path" => "a.txt", "content" => "new"}, project)

      assert %{"type" => "diff", "path" => path, "oldText" => nil, "newText" => "new"} = Edits.diff_content(proposal)
      assert path == Path.join(project, "a.txt")
    end
  end

  test "resolve/2 puts a relative path in the editor's project and leaves an absolute one alone", %{project: project} do
    assert Edits.resolve("lib/a.ex", project) == Path.join(project, "lib/a.ex")
    assert Edits.resolve("/etc/hosts", project) == "/etc/hosts"
    assert Edits.resolve("../x", project) == Path.join(Path.dirname(project), "x")
  end
end
