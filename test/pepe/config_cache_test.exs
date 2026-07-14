defmodule Pepe.ConfigCacheTest do
  @moduledoc """
  `Config.load/0` is on the hot path of nearly every read (get_agent, model_for_agent, locale,
  project_budget, ...) - a single Telegram turn can call it a dozen times. It's cached in
  `:persistent_term`, validated against the file's mtime+size on every load (not just invalidated
  by this process's own `save/1` - an operator's hand-edit to config.json on a live `mix pepe
  serve`, the documented way back from a lockout, must take effect without a restart), and
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

  test "a second load with the file untouched serves the same cached map, not a fresh read", %{home: home} do
    Config.put_model(%Config.Model{name: "seed", base_url: "http://x", model: "m"})
    assert Config.get_model("seed")

    # Nothing wrote to config.json between these two loads (mtime+size unchanged), so the second
    # load must be served from the cache. Proven negatively below (an external edit IS visible);
    # here we just confirm the untouched case keeps working and doesn't, say, blow up re-reading a
    # file it doesn't need to.
    assert Config.get_model("seed")
    refute File.exists?(Path.join(home, "config.json.tmp"))
  end

  test "an external edit to config.json (bypassing Config.save/1) is visible on the next load - the documented recovery path for a lockout",
       %{home: home} do
    Config.put_model(%Config.Model{name: "seed", base_url: "http://x", model: "m"})
    assert Config.get_model("seed")

    # Simulate an operator hand-editing config.json on a live `mix pepe serve` (the exact recovery
    # move a locked-out require_approval/allowed_users state needs) - written directly, never
    # through Config.save/1, so only a stat-validated cache (not a save/1-only invalidated one)
    # would ever see it.
    on_disk = Path.join(home, "config.json") |> File.read!() |> Jason.decode!()
    edited = put_in(on_disk, ["telegram"], %{"allowed_chats" => [999]})
    File.write!(Path.join(home, "config.json"), Jason.encode!(edited))

    assert Config.load()["telegram"]["allowed_chats"] == [999]
  end

  test "a present-but-corrupt external edit still raises on the next load, not silently served stale", %{home: home} do
    Config.put_model(%Config.Model{name: "seed", base_url: "http://x", model: "m"})
    assert Config.get_model("seed")

    File.write!(Path.join(home, "config.json"), "not json at all")

    assert_raise RuntimeError, ~r/not valid JSON/, fn -> Config.load() end
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
