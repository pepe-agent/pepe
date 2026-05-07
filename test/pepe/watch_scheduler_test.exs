defmodule Pepe.Watch.SchedulerTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Watch
  alias Pepe.Watch.Delivery
  alias Pepe.Watch.Scheduler

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_wsch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{}))

    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp put(attrs) do
    w = struct(%Watch{id: "w#{System.unique_integer([:positive])}", interval_s: 120}, attrs)
    Config.put_watch(w)
    w.id
  end

  defp tick, do: send(Scheduler, :tick)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "a due watch whose probe passes fires, delivers, and becomes done" do
    id =
      put(
        trigger: %{"type" => "probe", "command" => "exit 0"},
        on_fire: %{"type" => "template", "text" => "up"},
        origin: %{"channel" => "log"}
      )

    tick()
    # match?/2 rather than `.state ==`: the watch can be absent for a tick, and reading a
    # field off nil raises inside the predicate, which kills the retry that exists to
    # tolerate exactly that.
    wait_until(fn -> match?(%{state: "done"}, Config.get_watch(id)) end)
    assert Config.get_watch(id).pending_delivery == nil
  end

  test "a probe that isn't satisfied stays pending and bumps the counter" do
    id = put(trigger: %{"type" => "probe", "command" => "exit 1"}, origin: %{"channel" => "log"})

    tick()
    wait_until(fn -> Config.get_watch(id).checks == 1 end)
    assert Config.get_watch(id).state == "pending"
  end

  test "firing to a live subscribed surface delivers the message" do
    origin = %{"channel" => "ws", "key" => "ws:test-#{System.unique_integer([:positive])}"}
    {:ok, _} = Registry.register(Pepe.Watch.Subscribers, Delivery.topic(origin), nil)
    Phoenix.PubSub.subscribe(Pepe.PubSub, Delivery.topic(origin))

    id =
      put(
        trigger: %{"type" => "probe", "command" => "exit 0"},
        on_fire: %{"type" => "template", "text" => "deploy done"},
        origin: origin
      )

    tick()
    assert_receive {:watch_message, ^origin, "deploy done"}, 2_000
    # match?/2 rather than `.state ==`: the watch can be absent for a tick, and reading a
    # field off nil raises inside the predicate, which kills the retry that exists to
    # tolerate exactly that.
    wait_until(fn -> match?(%{state: "done"}, Config.get_watch(id)) end)
    assert Config.get_watch(id).pending_delivery == nil
  end

  test "firing with no live surface holds the message for later delivery" do
    origin = %{"channel" => "ws", "key" => "ws:offline-#{System.unique_integer([:positive])}"}

    id =
      put(
        trigger: %{"type" => "probe", "command" => "exit 0"},
        on_fire: %{"type" => "template", "text" => "held"},
        origin: origin
      )

    tick()
    # match?/2 rather than `.state ==`: the watch can be absent for a tick, and reading a
    # field off nil raises inside the predicate, which kills the retry that exists to
    # tolerate exactly that.
    wait_until(fn -> match?(%{state: "done"}, Config.get_watch(id)) end)
    assert Config.get_watch(id).pending_delivery == "held"
  end
end
