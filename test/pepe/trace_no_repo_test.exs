defmodule Pepe.TraceNoRepoTest do
  @moduledoc """
  Regression: `Pepe.Trace.finish/1`'s rescue used to swallow a Repo hiccup with no trace
  of it anywhere and, worse, returned `:ok` instead of the id its own doc promises -
  unlike `Pepe.Config.Journal.record/4`'s equivalent tolerance, which logs a warning and
  keeps its normal return shape. Deliberately the one trace test file that does NOT call
  `Pepe.RepoSetup.start!()` (every other one does, which is exactly why none of them could
  catch this), so `finish/1` hits a real "Repo not started" case instead of a simulated
  one.

  The Repo-not-running case is now checked up front rather than raised-and-rescued, so
  `finish/1` finishes normally and returns the id either way - it's the normal state of
  nearly every other test in this suite, not worth a `:warning`/an exception every time
  one runs, so it's noted at `:debug` instead (real, just quiet by default; `capture_log`
  can't prove a `:debug` line exists without lowering the suite's own configured `:warning`
  floor globally, which risks bleeding into unrelated concurrent tests, so this asserts the
  behavior that actually matters here - finish/1 not silently losing the run - instead).
  """
  use ExUnit.Case, async: false

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

  test "finish/1 tolerates Repo not being started, and still returns the trace id" do
    assert Trace.start("bot", nil) == :started
    assert is_binary(Trace.finish({:ok, "done", []}))
  end
end
