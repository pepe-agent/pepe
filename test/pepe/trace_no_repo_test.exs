defmodule Pepe.TraceNoRepoTest do
  @moduledoc """
  Regression: `Pepe.Trace.finish/1`'s rescue used to swallow a Repo hiccup with no trace
  of it anywhere - unlike `Pepe.Config.Journal.record/4`'s equivalent tolerance, which
  logs a warning. Deliberately the one trace test file that does NOT call
  `Pepe.RepoSetup.start!()` (every other one does, which is exactly why none of them could
  catch this), so `finish/1` hits a real "Repo not started" error instead of a simulated
  one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_trace_no_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    :ok
  end

  test "finish/1 tolerates Repo not being started, and logs it instead of staying silent" do
    assert Trace.start("bot", nil) == :started

    log =
      capture_log(fn ->
        assert Trace.finish({:ok, "done", []}) == :ok
      end)

    assert log =~ "[trace]"
  end
end
