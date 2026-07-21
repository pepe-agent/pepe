defmodule Pepe.ConfigTest do
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

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

  describe "get_agent name matching" do
    test "resolves an agent by name case-insensitively, exact match preferred" do
      Config.put_agent(%Config.Agent{name: "Engenheiro", tools: []})

      # All three casings resolve to the same agent (its name is the qualified handle).
      assert Config.get_agent("Engenheiro").name == "default/Engenheiro"
      assert Config.get_agent("engenheiro").name == "default/Engenheiro"
      assert Config.get_agent("ENGENHEIRO").name == "default/Engenheiro"
      assert Config.get_agent("nope") == nil
    end

    test "put_agent refuses a name that only differs in case from an existing agent, rather than silently overwriting it" do
      :ok = Config.put_agent(%Config.Agent{name: "Engenheiro", system_prompt: "original", tools: ["bash"]})

      assert Config.put_agent(%Config.Agent{name: "engenheiro", system_prompt: "different"}) == {:error, :name_collision}

      # Untouched: the collision was refused, not silently merged into the existing agent.
      original = Config.get_agent("Engenheiro")
      assert original.system_prompt == "original"
      assert original.tools == ["bash"]
      assert map_size(Config.load()["agents"]) == 1
    end

    test "put_agent still allows an exact-name update (upsert by name, unrelated to case collisions)" do
      :ok = Config.put_agent(%Config.Agent{name: "Engenheiro", system_prompt: "v1"})
      :ok = Config.put_agent(%Config.Agent{name: "Engenheiro", system_prompt: "v2"})

      assert Config.get_agent("Engenheiro").system_prompt == "v2"
      assert map_size(Config.load()["agents"]) == 1
    end

    test "rename_agent refuses renaming into a name that only differs in case from a different agent" do
      Config.put_agent(%Config.Agent{name: "Engenheiro", tools: []})
      Config.put_agent(%Config.Agent{name: "Suporte", tools: []})

      assert Config.rename_agent("Suporte", "engenheiro") == {:error, :already_exists}
      # Untouched.
      assert Config.get_agent("Suporte").name == "default/Suporte"
    end

    test "rename_agent still allows changing only the casing of an agent's own name" do
      Config.put_agent(%Config.Agent{name: "Engenheiro", tools: []})

      assert Config.rename_agent("Engenheiro", "engenheiro") == :ok
      assert Config.get_agent("engenheiro").name == "default/engenheiro"
    end
  end

  describe "get_project slug matching" do
    test "resolves a project by slug case-insensitively, exact match preferred" do
      :ok = Config.add_project("Acme")

      assert Config.get_project("Acme")["slug"] == "Acme"
      assert Config.get_project("acme")["slug"] == "Acme"
      assert Config.get_project("ACME")["slug"] == "Acme"
      assert Config.get_project("nope") == nil
    end

    test "add_project refuses a slug that only differs in case from an existing project" do
      :ok = Config.add_project("Acme")
      assert Config.add_project("acme") == {:error, :already_exists}
      assert Config.add_project("ACME") == {:error, :already_exists}
    end

    test "rename_project refuses renaming into a different project's slug (case-insensitively)" do
      :ok = Config.add_project("Acme")
      :ok = Config.add_project("Globex")

      assert Config.rename_project("Globex", "acme") == {:error, :already_exists}
      assert Config.get_project("Globex")["slug"] == "Globex"
    end

    test "rename_project still allows changing only the casing of a project's own slug" do
      :ok = Config.add_project("Acme")

      assert Config.rename_project("Acme", "acme") == :ok
      assert Config.get_project("acme")["slug"] == "acme"
    end
  end

  describe "get_model name matching" do
    test "resolves a model by name case-insensitively, exact match preferred" do
      Config.put_model(%Config.Model{name: "OpenAI", base_url: "u", model: "m"})

      assert Config.get_model("OpenAI").name == "OpenAI"
      assert Config.get_model("openai").name == "OpenAI"
      assert Config.get_model("OPENAI").name == "OpenAI"
      assert Config.get_model("nope") == nil
    end

    test "put_model refuses a name that only differs in case from an existing connection, rather than silently overwriting it" do
      :ok = Config.put_model(%Config.Model{name: "OpenAI", base_url: "original", api_key: "k1", model: "m"})

      assert Config.put_model(%Config.Model{name: "openai", base_url: "different", model: "m"}) ==
               {:error, :name_collision}

      original = Config.get_model("OpenAI")
      assert original.base_url == "original"
      assert original.api_key == "k1"
      assert map_size(Config.load()["models"]) == 1
    end

    test "put_model still allows an exact-name update (upsert by name, unrelated to case collisions)" do
      :ok = Config.put_model(%Config.Model{name: "OpenAI", base_url: "v1", model: "m"})
      :ok = Config.put_model(%Config.Model{name: "OpenAI", base_url: "v2", model: "m"})

      assert Config.get_model("OpenAI").base_url == "v2"
      assert map_size(Config.load()["models"]) == 1
    end
  end

  describe "create_commitment/1" do
    test "stores a fresh commitment and resolves the agent handle back" do
      Config.put_agent(%Config.Agent{name: "assistant", tools: []})

      assert {:ok, c} =
               Config.create_commitment(%Config.Commitment{
                 text: "check the deploy and report back",
                 agent: "assistant",
                 origin_type: "agent_promise",
                 state: "scheduled"
               })

      assert c.agent == "default/assistant"
      assert c.text == "check the deploy and report back"
      assert [^c] = Config.commitments()
    end

    test "skips a near-duplicate for the same agent, punctuation/case-insensitive" do
      Config.put_agent(%Config.Agent{name: "assistant", tools: []})

      assert {:ok, _} =
               Config.create_commitment(%Config.Commitment{
                 text: "Check the deploy and report back!",
                 agent: "assistant",
                 state: "scheduled"
               })

      assert Config.create_commitment(%Config.Commitment{
               text: "check the deploy and report back",
               agent: "assistant",
               state: "awaiting_confirmation"
             }) == {:error, :duplicate}

      assert match?([_], Config.commitments())
    end

    test "does not treat a delivered/cancelled commitment as a duplicate" do
      Config.put_agent(%Config.Agent{name: "assistant", tools: []})

      {:ok, first} =
        Config.create_commitment(%Config.Commitment{text: "ping the user", agent: "assistant", state: "scheduled"})

      Config.put_commitment(%{first | state: "delivered"})

      assert {:ok, _} =
               Config.create_commitment(%Config.Commitment{text: "ping the user", agent: "assistant", state: "scheduled"})

      assert match?([_, _], Config.commitments())
    end

    test "only one of two concurrent near-duplicate extractions wins" do
      Config.put_agent(%Config.Agent{name: "assistant", tools: []})

      results =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Config.create_commitment(%Config.Commitment{text: "follow up tomorrow", agent: "assistant", state: "scheduled"})
          end)
        end)
        |> Task.await_many(10_000)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      dups = Enum.count(results, &(&1 == {:error, :duplicate}))
      assert oks == 1, "expected exactly one insert to win, got #{oks}"
      assert dups == 9
      assert match?([_], Config.commitments())
    end
  end

  describe "file permissions" do
    test "save restricts the config to owner-only and tightens the home directory" do
      Config.save(%{"x" => 1})

      # The config can hold a raw credential, so no group/other read or write.
      assert {:ok, %File.Stat{mode: config_mode}} = File.stat(Config.path())
      assert Bitwise.band(config_mode, 0o077) == 0, "config is #{Integer.to_string(config_mode, 8)}"

      # The home directory: no group/other write (0700 in practice).
      assert {:ok, %File.Stat{mode: home_mode}} = File.stat(Config.home())
      assert Bitwise.band(home_mode, 0o022) == 0
    end
  end
end
