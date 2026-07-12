defmodule Pepe.ConfigCacheTest do
  @moduledoc """
  `Config.load/0` is on the hot path of nearly every read (get_agent, model_for_agent, locale,
  project_budget, ...) - a single Telegram turn can call it a dozen times. It's cached in
  `:persistent_term`, invalidated at the one place every write funnels through (`save/1`), and
  deliberately off in the test env (see the moduledoc comment on `Config.load/0`) - so these tests
  force a non-test env to actually exercise the cached path, and restore it (and the persistent_term
  entry) afterwards so nothing leaks into the rest of the suite.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cfgcache_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    prev_env = Application.get_env(:pepe, :env)
    Application.put_env(:pepe, :env, :dev)

    on_exit(fn ->
      Application.put_env(:pepe, :env, prev_env)
      :persistent_term.erase(:pepe_config_cache)
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "a second load does not re-read the disk - it serves the cached map", %{home: home} do
    Config.put_model(%Config.Model{name: "seed", base_url: "http://x", model: "m"})
    assert Config.get_model("seed")

    # Corrupt the file on disk directly (bypassing Config.save/1 entirely). If load/0 were still
    # reading through, this would raise (Config.load/0 refuses a present-but-invalid file); getting
    # the pre-corruption model back instead proves the cache served it without touching disk.
    File.write!(Path.join(home, "config.json"), "not json at all")

    assert Config.get_model("seed")
  end

  test "save/1 refreshes the cache, so the very next load sees the new state", %{home: home} do
    Config.put_model(%Config.Model{name: "one", base_url: "http://x", model: "m"})
    assert Config.get_model("one")

    Config.put_model(%Config.Model{name: "two", base_url: "http://x", model: "m"})
    assert Config.get_model("one")
    assert Config.get_model("two")

    # And it's the same file the cache is fronting, not just an in-memory fork of it.
    on_disk = Path.join(home, "config.json") |> File.read!() |> Jason.decode!()
    assert Enum.any?(on_disk["models"], fn {_id, m} -> m["name"] == "two" end)
  end

  test "changing PEPE_HOME mid-process misses the old cache and reads the new location", %{home: home} do
    Config.put_model(%Config.Model{name: "in-old-home", base_url: "http://x", model: "m"})
    assert Config.get_model("in-old-home")

    other = Path.join(System.tmp_dir!(), "pepe_cfgcache_other_#{System.unique_integer([:positive])}")
    File.mkdir_p!(other)
    System.put_env("PEPE_HOME", other)

    # A stale, unkeyed cache would still show "in-old-home" here (the exact class of bug the
    # mix pepe setup home-relocation wizard could hit). It must not - and once the new home has
    # its own model, that one must be visible too.
    refute Config.get_model("in-old-home")
    Config.put_model(%Config.Model{name: "in-new-home", base_url: "http://x", model: "m"})
    assert Config.get_model("in-new-home")

    File.rm_rf(other)
    System.put_env("PEPE_HOME", home)
  end

  test "the cache is a no-op in the test env - the default for every other test in this suite" do
    Application.put_env(:pepe, :env, :test)
    :persistent_term.erase(:pepe_config_cache)

    Config.put_model(%Config.Model{name: "seed", base_url: "http://x", model: "m"})
    assert Config.get_model("seed")

    # Nothing was ever written to persistent_term - a direct disk edit is visible immediately.
    assert :persistent_term.get(:pepe_config_cache, :none) == :none
  end
end
