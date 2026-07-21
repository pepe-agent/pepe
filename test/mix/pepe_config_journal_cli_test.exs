defmodule Mix.Tasks.PepeConfigJournalCliTest do
  @moduledoc """
  `mix pepe config journal` is the CLI surface for `Pepe.Config.Journal` - the same
  "who touched config.json, when, which sections changed" list the dashboard's Config
  page already shows under "Recent changes".
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_config_journal_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_config_source)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "no changes yet says so" do
    out = pepe(["config", "journal"])
    assert out =~ "no config changes recorded yet"
  end

  test "shows the source and changed sections of a real write" do
    Pepe.Config.Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    out = pepe(["config", "journal"])
    assert out =~ "cli"
    assert out =~ "agents"
  end

  test "flags a write the running process didn't make as external" do
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    # Config.save/1 already writes pretty JSON, so re-encoding the same map the same way
    # is a same-size, likely same-mtime no-op - force a *different* mtime deterministically
    # (no real sleep) instead of waiting out its ~1s resolution by wall clock.
    raw = File.read!(Config.path())
    File.write!(Config.path(), raw)
    {mtime, _size} = Config.file_stamp()
    File.touch!(Config.path(), mtime + 2)

    Pepe.Config.Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "someone-else", tools: []})

    out = pepe(["config", "journal"])
    assert out =~ "external"
  end

  test "an invalid limit is refused with a usage message" do
    out = pepe_err(["config", "journal", "not-a-number"])
    assert out =~ "usage: pepe config journal"
  end
end
