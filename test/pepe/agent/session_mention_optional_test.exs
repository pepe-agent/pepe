defmodule Pepe.Agent.SessionMentionOptionalTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_mentionopt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "greeter", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:mention:#{System.unique_integer([:positive])}"}
  end

  test "off by default, toggles on demand", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "greeter")

    refute Session.mention_optional?(key)
    assert Session.set_mention_optional(key, true) == :ok
    assert Session.mention_optional?(key)

    assert Session.set_mention_optional(key, false) == :ok
    refute Session.mention_optional?(key)
  end

  test "reset clears the waiver back to false", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "greeter")

    Session.set_mention_optional(key, true)
    assert Session.mention_optional?(key)

    Session.reset(key)
    refute Session.mention_optional?(key)
  end

  test "is scoped to its own session key, not shared across chats", %{key: key} do
    other_key = key <> ":other"
    {:ok, _pid} = SessionSupervisor.ensure(key, "greeter")
    {:ok, _pid2} = SessionSupervisor.ensure(other_key, "greeter")

    Session.set_mention_optional(key, true)

    assert Session.mention_optional?(key)
    refute Session.mention_optional?(other_key)
  end
end
