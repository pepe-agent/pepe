defmodule Pepe.Config.JournalTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Journal

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_journal_#{System.unique_integer([:positive])}")
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

  test "source defaults to unknown, and put_source/1 tags the calling process" do
    assert Journal.source() == "unknown"
    Journal.put_source("dashboard")
    assert Journal.source() == "dashboard"
  end

  test "a config write is journaled with its source and the changed top-level keys" do
    Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    [entry | _] = Journal.recent()
    assert entry["source"] == "cli"
    assert "agents" in entry["changed"]
    assert entry["external"] == false
  end

  # Regression: a single `mix pepe` one-shot never has the Writer GenServer running (only
  # `mix pepe serve`/gateways do), so `update/1` falls back to running inline - and that
  # fallback used to hardcode the literal string "unknown" instead of reading the caller's
  # own tagged source, silently losing "cli" on the single most common way this ships.
  test "source tagging survives the inline fallback (no Writer process running)" do
    Journal.put_source("cli")
    GenServer.stop(Pepe.Config.Writer, :normal)

    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    [entry | _] = Journal.recent()
    assert entry["source"] == "cli"
  after
    wait_for_writer()
  end

  defp wait_for_writer(tries \\ 50) do
    cond do
      Process.whereis(Pepe.Config.Writer) -> :ok
      tries <= 0 -> flunk("Pepe.Config.Writer never came back up")
      true -> Process.sleep(20) && wait_for_writer(tries - 1)
    end
  end

  test "a write with no actual change is not journaled" do
    Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})
    before = length(Journal.recent())

    # Same exact write again - agents section content is identical.
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    assert length(Journal.recent()) == before
  end

  test "recent/1 returns newest first and respects the limit" do
    Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "a1", tools: []})
    Config.put_agent(%Config.Agent{name: "a2", tools: []})
    Config.put_agent(%Config.Agent{name: "a3", tools: []})

    [newest, middle] = Journal.recent(2)
    assert newest["at"] >= middle["at"]
  end

  test "record/4 never writes a value, only key names" do
    Journal.put_source("cli")
    Config.put_model(%Config.Model{name: "openai", base_url: "x", api_key: "sk-super-secret", model: "gpt"})

    [entry | _] = Journal.recent()
    refute Jason.encode!(entry) =~ "sk-super-secret"
    assert "models" in entry["changed"]
  end

  test "a write the running process didn't make is flagged external" do
    Config.put_agent(%Config.Agent{name: "assistant", tools: []})

    # Simulate a hand-edit: touch the file directly, bypassing Config.Writer entirely,
    # then make a real write through the writer and confirm it notices the gap.
    # `Config.save/1` already writes pretty-printed JSON, so re-encoding the same map the
    # same way is a same-size, likely same-mtime no-op - not the "editor saved this file"
    # the writer needs to actually see. Force a *different* mtime deterministically (no
    # real sleep, unlike waiting out mtime's ~1s resolution by wall clock) so the stamp
    # {mtime, size} file_stamp/0 compares is guaranteed to differ.
    raw = File.read!(Config.path())
    File.write!(Config.path(), raw)
    {mtime, _size} = Config.file_stamp()
    File.touch!(Config.path(), mtime + 2)

    Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "someone-else", tools: []})

    [entry | _] = Journal.recent()
    assert entry["external"] == true
  end
end
