defmodule Pepe.RepoLazyStartTest do
  @moduledoc """
  Regression: `mix pepe agent`/`project` remove/rename and `extract` dispatch through
  `with_config` (`lib/mix/tasks/pepe.ex`), which used to only start `:jason` - never the
  app, never `Pepe.Repo`. Once those code paths started touching commitments
  unconditionally, every one of them crashed on a real install with `could not lookup Ecto
  repo Pepe.Repo because it was not started` (found by an adversarial review, reproduced
  by hand before this test existed). Every OTHER test in this suite calls
  `Pepe.RepoSetup.start!()` in its own setup, which is exactly why none of them caught
  this - this is deliberately the one file that does NOT, and dispatches through the real
  CLI entry point (not `Pepe.Config` directly), to prove `with_config` itself now
  guarantees `Pepe.Repo` is available, not just something that happens to already be
  running because a test (or `with_app`) started it first.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_repo_lazy_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    # Deliberately no Pepe.RepoSetup.start!() here - that is the whole point of this file.

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "mix pepe agent remove works without the app (or Pepe.Repo) ever having been started" do
    refute Process.whereis(Pepe.Repo)

    pepe(["agent", "add", "vendas", "--prompt", "x"])
    out = pepe(["agent", "remove", "vendas"])

    assert out =~ "removed"
    assert Config.get_agent("vendas") == nil
  end

  test "mix pepe project rename rebinds without the app (or Pepe.Repo) ever having been started" do
    refute Process.whereis(Pepe.Repo)

    pepe(["project", "add", "acme"])
    pepe(["agent", "add", "vendas", "--project", "acme", "--prompt", "x"])
    out = pepe(["project", "rename", "acme", "umbrella"])

    assert out =~ "renamed"
    assert Config.get_agent("umbrella/vendas") != nil
  end

  test "mix pepe extract works without the app (or Pepe.Repo) ever having been started" do
    refute Process.whereis(Pepe.Repo)

    pepe(["project", "add", "acme"])
    pepe(["agent", "add", "vendas", "--project", "acme", "--prompt", "x"])

    out = Path.join(System.tmp_dir!(), "acme_lazy_#{System.unique_integer([:positive])}.tgz")
    on_exit(fn -> File.rm_rf(out) end)

    result = pepe(["extract", "acme", "--output", out])

    assert result =~ "extracted"
    assert File.regular?(out)
  end
end
