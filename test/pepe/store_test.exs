defmodule Pepe.StoreTest do
  use ExUnit.Case, async: false

  alias Pepe.Store

  setup_all do
    home = Path.join(System.tmp_dir!(), "pepe_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      :mnesia.stop()
      :persistent_term.erase({Pepe.Store, :ready})
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "put/get round-trips arbitrary Elixir terms" do
    Store.put(:session, "k1", %{a: 1, b: [2, 3]})
    assert Store.get(:session, "k1") == %{a: 1, b: [2, 3]}
  end

  test "get returns nil for a missing key" do
    assert Store.get(:session, "missing") == nil
  end

  test "delete removes an entry" do
    Store.put(:session, "k2", "value")
    Store.delete(:session, "k2")
    assert Store.get(:session, "k2") == nil
  end

  test "an expired ttl hides the entry on read" do
    Store.put(:cache, "stale", "bye", ttl: -1)
    assert Store.get(:cache, "stale") == nil
  end

  test "all/1 lists live entries in a namespace" do
    Store.put(:mem, "a", 1)
    Store.put(:mem, "b", 2)
    Store.put(:other, "c", 3)

    assert Enum.sort(Store.all(:mem)) == [{"a", 1}, {"b", 2}]
  end

  test "expire/0 purges entries past their ttl" do
    Store.put(:gc, "dead", 1, ttl: -1)
    Store.put(:gc, "alive", 2, ttl: 3600)

    assert Store.expire() >= 1
    assert Store.get(:gc, "dead") == nil
    assert Store.get(:gc, "alive") == 2
  end
end
