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
    assert {:ok, "zak", ^msgs, [], nil} = P.load("telegram:42")
  end

  test "save/load round-trips the reversible PII map" do
    msgs = [%{"role" => "user", "content" => "hi PERSON_1"}]
    pii = [%{"fake" => "PERSON_1", "real" => "Alice"}]
    assert :ok = P.save("web:pii", "zak", msgs, pii)
    assert {:ok, "zak", ^msgs, ^pii, nil} = P.load("web:pii")
  end

  test "loading a legacy file with no pii_map field defaults it to []" do
    # A session file written before pii_map persistence existed must still load cleanly.
    dir = P.dir()
    File.mkdir_p!(dir)
    legacy = %{"key" => "web:legacy", "agent_name" => "zak", "messages" => [], "pending" => nil}
    File.write!(Path.join(dir, Base.url_encode64("web:legacy", padding: false) <> ".json"), Jason.encode!(legacy))

    assert {:ok, "zak", [], [], nil} = P.load("web:legacy")
  end

  test "load returns :error when absent" do
    assert P.load("web:nope") == :error
  end

  test "all lists every saved session as {key, agent, pending}" do
    P.save("web:1", "zak", [])
    P.save("telegram:9", "vega", [])
    assert Enum.sort(P.all()) == [{"telegram:9", "vega", nil}, {"web:1", "zak", nil}]
  end

  test "delete removes the file" do
    P.save("web:1", "zak", [])
    assert :ok = P.delete("web:1")
    assert P.load("web:1") == :error
    assert P.all() == []
  end

  test "keys with ':' and '/' get a safe filename" do
    assert :ok = P.save("api:a/b:c", "zak", [])
    assert {:ok, "zak", [], [], nil} = P.load("api:a/b:c")
  end

  test "mark_pending sets the marker without touching agent/messages" do
    msgs = [%{"role" => "user", "content" => "hi"}]
    P.save("web:1", "zak", msgs)

    assert :ok = P.mark_pending("web:1", "are you there?")
    assert {:ok, "zak", ^msgs, [], "are you there?"} = P.load("web:1")
  end

  test "mark_pending on a session with no prior save still records the marker" do
    assert :ok = P.mark_pending("web:2", "first message")
    assert {:ok, nil, [], [], "first message"} = P.load("web:2")
  end

  test "clear_pending drops the marker, keeps history" do
    msgs = [%{"role" => "user", "content" => "hi"}]
    P.save("web:1", "zak", msgs)
    P.mark_pending("web:1", "are you there?")

    assert :ok = P.clear_pending("web:1")
    assert {:ok, "zak", ^msgs, [], nil} = P.load("web:1")
  end

  test "a normal save implicitly clears any pending marker" do
    P.mark_pending("web:1", "are you there?")
    P.save("web:1", "zak", [])

    assert {:ok, "zak", [], [], nil} = P.load("web:1")
  end

  test "all() surfaces the pending marker" do
    P.save("web:1", "zak", [])
    P.mark_pending("web:1", "are you there?")

    assert P.all() == [{"web:1", "zak", "are you there?"}]
  end
end
