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
    raw = File.read!(Config.path())
    File.write!(Config.path(), raw)
    # Force a different mtime+size than what the writer last recorded, the same way an
    # editor saving the file would - append whitespace inside the JSON is invalid, so
    # instead wait a tick and rewrite with a trivial reformat (still valid JSON).
    Process.sleep(1100)
    File.write!(Config.path(), Jason.encode!(Jason.decode!(raw), pretty: true))

    Journal.put_source("cli")
    Config.put_agent(%Config.Agent{name: "someone-else", tools: []})

    [entry | _] = Journal.recent()
    assert entry["external"] == true
  end
end
