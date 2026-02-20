defmodule Pepe.Agent.SessionPersistenceTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.SessionPersistence, as: P

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "save/load round-trips a session" do
    msgs = [%{"role" => "system", "content" => "x"}, %{"role" => "user", "content" => "hi"}]
    assert :ok = P.save("telegram:42", "zak", msgs)
    assert {:ok, "zak", ^msgs} = P.load("telegram:42")
  end

  test "load returns :error when absent" do
    assert P.load("web:nope") == :error
  end

  test "all lists every saved session as {key, agent}" do
    P.save("web:1", "zak", [])
    P.save("telegram:9", "vega", [])
    assert Enum.sort(P.all()) == [{"telegram:9", "vega"}, {"web:1", "zak"}]
  end

  test "delete removes the file" do
    P.save("web:1", "zak", [])
    assert :ok = P.delete("web:1")
    assert P.load("web:1") == :error
    assert P.all() == []
  end

  test "keys with ':' and '/' get a safe filename" do
    assert :ok = P.save("api:a/b:c", "zak", [])
    assert {:ok, "zak", []} = P.load("api:a/b:c")
  end
end
