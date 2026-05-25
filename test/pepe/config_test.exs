defmodule Pepe.ConfigTest do
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  describe "short_path/1" do
    test "shows $PEPE_HOME when the home override is set" do
      assert Config.short_path(Config.path()) == "$PEPE_HOME/config.json"
      assert Config.short_path(Path.join(Config.home(), "data/x")) == "$PEPE_HOME/data/x"
    end

    test "leaves an unrelated absolute path untouched" do
      assert Config.short_path("/etc/hosts") == "/etc/hosts"
    end
  end

  describe "migration freezes minted ids on first load (id stability)" do
    test "a legacy config migrates once, persists, and resolves identically across later loads" do
      legacy =
        Jason.encode!(%{
          "default_model" => "mock",
          "default_agent" => "assistant",
          "models" => %{"mock" => %{"base_url" => "u", "api_key" => "k", "model" => "m"}},
          "agents" => %{"assistant" => %{"model" => "mock", "system_prompt" => "hi"}}
        })

      File.write!(Config.path(), legacy)

      # The migrations mint random ids each run, so they are not idempotent across separate load/0
      # calls: the first load must freeze them to disk. If it didn't, a second load would re-mint
      # different ids and the agent's stored model id would resolve to nothing. Both resolutions
      # (each its own load) must agree.
      assert Config.model_for_agent(Config.get_agent("assistant")).model == "m"
      assert Config.model_for_agent(Config.get_agent("assistant")).model == "m"

      migrated = Jason.decode!(File.read!(Config.path()))
      assert Map.has_key?(migrated, "projects")
      assert Map.has_key?(migrated, "default_project")
    end
  end

  describe "backup/0" do
    test "returns nil when there is no config file yet" do
      assert Config.backup() == nil
    end

    test "copies the config to a timestamped .bak and returns its path" do
      Config.put_model(%Config.Model{name: "m", base_url: "x", model: "id"})

      bak = Config.backup()

      assert is_binary(bak)
      assert bak =~ ~r/\.bak\.\d+$/
      assert File.exists?(bak)
      assert File.read!(bak) == File.read!(Config.path())
    end

    test "keeps only the last few backups, pruning the oldest", %{home: home} do
      Config.put_model(%Config.Model{name: "m", base_url: "x", model: "id"})
      base = Path.basename(Config.path())

      # Seed several older backups with distinct (small) timestamps.
      for ts <- 1000..1006, do: File.write!(Path.join(home, "#{base}.bak.#{ts}"), "old")

      # A real backup (current unix time, sorts newest) triggers the prune.
      Config.backup()

      baks = File.ls!(home) |> Enum.filter(&String.starts_with?(&1, "#{base}.bak."))
      assert [_, _, _, _, _] = baks
      refute Enum.any?(baks, &String.ends_with?(&1, ".bak.1000"))
    end
  end
end
