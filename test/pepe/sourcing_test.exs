defmodule Pepe.SourcingTest do
  @moduledoc """
  The shared download/stage logic `Pepe.Plugins` and `Pepe.Skills.Marketplace` both build on.
  """
  use ExUnit.Case, async: true

  alias Pepe.Sourcing

  test "github_target parses owner/repo and an optional branch" do
    assert Sourcing.github_target("/octocat/Hello-World") == {"octocat", "Hello-World", nil}
    assert Sourcing.github_target("/user/repo/tree/dev") == {"user", "repo", "dev"}
    assert Sourcing.github_target("/user/repo.git") == {"user", "repo", nil}
    assert Sourcing.github_target("/onlyone") == nil
  end

  describe "github_repo?/2" do
    test "a bare GitHub repo link is a repo, not a direct file" do
      assert Sourcing.github_repo?("https://github.com/octocat/Hello-World", ".exs")
      assert Sourcing.github_repo?("https://github.com/octocat/Hello-World/tree/dev", ".exs")
    end

    test "a direct link to a file of the caller's single_ext is not treated as a repo" do
      refute Sourcing.github_repo?("https://github.com/octocat/repo/raw/main/tool.exs", ".exs")
    end

    test "an archive link is not treated as a repo" do
      refute Sourcing.github_repo?("https://github.com/octocat/repo/archive/refs/heads/main.tar.gz", ".exs")
    end

    test "a non-GitHub host is never a repo link" do
      refute Sourcing.github_repo?("https://example.com/octocat/Hello-World", ".exs")
    end
  end

  describe "stage/3 with a local path" do
    test "a missing path is reported" do
      assert {:error, :not_found} = Sourcing.stage("/no/such/path-#{System.unique_integer([:positive])}", ".exs", fn _ -> false end)
    end

    test "a local directory stages as :dir, unchanged" do
      dir = Path.join(System.tmp_dir!(), "pepe_src_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, %{type: :dir, path: ^dir}, cleanup} = Sourcing.stage(dir, ".exs", fn _ -> false end)
      assert cleanup.() == :ok
    end

    test "a bare file matching single_ext stages as :file" do
      file = Path.join(System.tmp_dir!(), "pepe_src_file_#{System.unique_integer([:positive])}.exs")
      File.write!(file, "# hi")
      on_exit(fn -> File.rm(file) end)

      assert {:ok, %{type: :file, path: ^file}, _cleanup} = Sourcing.stage(file, ".exs", fn _ -> false end)
    end

    test "a file whose extension doesn't match single_ext, and isn't an archive, is unsupported" do
      file = Path.join(System.tmp_dir!(), "pepe_src_bad_#{System.unique_integer([:positive])}.txt")
      File.write!(file, "hi")
      on_exit(fn -> File.rm(file) end)

      assert {:error, :unsupported_source} = Sourcing.stage(file, ".exs", fn _ -> false end)
    end

    test "a .tar.gz is extracted, and root/2 picks the dir matching the marker" do
      src = Path.join(System.tmp_dir!(), "pepe_src_pkg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(src, "nested"))
      File.write!(Path.join([src, "nested", "tool.exs"]), "# a tool")
      archive = Path.join(System.tmp_dir!(), "pepe_src_pkg_#{System.unique_integer([:positive])}.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", archive, "-C", src, "nested"])

      on_exit(fn ->
        File.rm_rf(src)
        File.rm(archive)
      end)

      assert {:ok, %{type: :dir, path: root}, cleanup} =
               Sourcing.stage(archive, ".exs", fn name -> String.ends_with?(name, ".exs") end)

      assert File.regular?(Path.join(root, "tool.exs"))
      cleanup.()
      refute File.dir?(root)
    end
  end
end
