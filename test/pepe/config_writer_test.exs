defmodule Pepe.ConfigWriterTest do
  @moduledoc """
  Config is a plain JSON file and every mutation is load→modify→save. Run concurrently, two of
  those could each load the same state, change different slices, and have the last save drop the
  other's change - a lost update. `Pepe.Config.Writer` serializes them; this proves no write is
  lost under contention.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent

  setup do
    # The writer must be running to serialize; it's part of the app supervision tree.
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_writer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "concurrent grants to different agents don't clobber each other" do
    names = for i <- 1..40, do: "agent#{i}"
    for name <- names, do: Config.put_agent(%Agent{name: name, system_prompt: "x", tools: []})

    # 40 processes each authorize a distinct tool on a distinct agent, all at once. A load→save
    # that didn't serialize would drop most of these (each save writes back the whole config it
    # loaded, blind to the others).
    names
    |> Enum.map(fn name ->
      Task.async(fn -> Config.allow_tool(name, "bash:#{name}") end)
    end)
    |> Task.await_many(10_000)

    # Every single grant survived.
    for name <- names do
      assert Config.get_agent(name).auto_approve == ["bash:#{name}"],
             "#{name}'s grant was lost to a concurrent write"
    end
  end

  test "concurrent writes to the SAME agent all apply (read-modify-write is atomic)" do
    Config.put_agent(%Agent{name: "shared", system_prompt: "x", tools: []})

    # 20 processes each add a distinct route to the same agent. Each is a read-modify-write of the
    # same entry; without an atomic update the last writer would win and only one route would
    # remain. With `update_agent` reading inside the lock, all accumulate.
    routes = for i <- 1..20, do: "peer#{i}"

    routes
    |> Enum.map(fn peer -> Task.async(fn -> Config.allow_message("shared", peer) end) end)
    |> Task.await_many(10_000)

    can_message = Config.get_agent("shared").can_message
    # A bare peer qualifies into the sender's (default) project, so the stored route is `default/peerN`.
    for peer <- routes, do: assert("default/#{peer}" in can_message, "route to #{peer} was lost")
  end
end
