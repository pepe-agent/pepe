defmodule Mix.Tasks.PepeCheckpointsCliTest do
  @moduledoc """
  `mix pepe checkpoints` is the operator's view of the saved file states `/rewind` puts
  back: what is held, a way to prune now and a way to delete it all. And the two agent
  switches (`--no-checkpoints`, `--checkpoint-shell`) that decide what gets saved at all.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Agent.Workspace
  alias Pepe.Checkpoints
  alias Pepe.Checkpoints.Store
  alias Pepe.Config

  @key "cli:checkpoints"

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_checkpoints_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_config_source)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  # One recorded file change, the way a real write_file leaves it.
  defp record_a_change do
    agent = %{name: "zak", checkpoints: true, checkpoint_shell: false}
    workspace = Workspace.dir("zak")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "notes.md"), "original")
    ctx = %{agent: agent, session_key: @key, cwd: workspace}

    Checkpoints.around("write_file", %{"path" => "notes.md", "content" => "changed"}, ctx, fn ->
      File.write!(Path.join(workspace, "notes.md"), "changed")
      {:ok, "wrote"}
    end)
  end

  describe "status" do
    test "an empty store says so, and it is what a bare `checkpoints` shows" do
      out = pepe(["checkpoints"])

      assert out =~ "checkpoints"
      assert out =~ "held:      0 B"
      assert out =~ "records:   0 file changes"
      assert out =~ "kept for:  14 days"
      assert pepe(["checkpoints", "status"]) == out
    end

    test "counts what a real file change left behind" do
      record_a_change()

      out = pepe(["checkpoints", "status"])

      assert out =~ "records:   1 file changes"
      refute out =~ "held:      0 B"
      assert out =~ "oldest:"
    end
  end

  describe "prune and clear" do
    test "prune keeps what is recent and reports what it dropped" do
      record_a_change()

      assert pepe(["checkpoints", "prune"]) =~ "pruned 0 old records and 0 unused copies"
      assert Store.bytes() > 0
    end

    test "clear deletes all of it and says what that costs" do
      record_a_change()

      out = pepe(["checkpoints", "clear"])

      assert out =~ "deleted every checkpoint"
      assert out =~ "/rewind can no longer put files back for earlier turns"
      assert pepe(["checkpoints", "status"]) =~ "records:   0 file changes"
    end

    test "something it does not know is a usage error, not a guess" do
      assert pepe_err(["checkpoints", "explode"]) =~ "usage: mix pepe checkpoints [status|prune|clear]"
    end

    test "help explains the switches that control what is saved" do
      out = pepe(["checkpoints", "help"])

      assert out =~ "checkpoints prune"
      assert out =~ "--no-checkpoints"
    end
  end

  describe "the agent switches" do
    setup do
      Config.put_model(%Config.Model{name: "m", base_url: "https://x", model: "gpt"})
      :ok
    end

    test "an agent saves file states by default, without the shell" do
      pepe(["agent", "add", "plain", "--model", "m"])

      agent = Config.get_agent("plain")
      assert agent.checkpoints == true
      assert agent.checkpoint_shell == false
    end

    test "--no-checkpoints turns it off, --checkpoint-shell extends it to shell commands" do
      pepe(["agent", "add", "quiet", "--model", "m", "--no-checkpoints"])
      pepe(["agent", "add", "thorough", "--model", "m", "--checkpoint-shell"])

      assert Config.get_agent("quiet").checkpoints == false
      assert Config.get_agent("thorough").checkpoint_shell == true
    end
  end
end
