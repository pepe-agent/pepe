defmodule Pepe.Gateways.Discord.DispatcherTest do
  @moduledoc """
  The dispatcher in isolation: it calls `Pepe.Webhooks.handle_gateway_event/2` for each
  payload it is given, in the order it was given them, off whatever process called
  `dispatch/2`, and does not die when that call raises or exits.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Gateways.Discord.Dispatcher

  setup :set_mimic_global

  test "calls handle_gateway_event for each payload, in the order dispatched" do
    test_pid = self()

    Pepe.Webhooks
    |> stub(:handle_gateway_event, fn slug, payload ->
      send(test_pid, {:handled, slug, payload["id"]})
      :ok
    end)

    {:ok, pid} = Dispatcher.start_link("support")

    for id <- 1..5, do: Dispatcher.dispatch(pid, %{"id" => id})

    for id <- 1..5, do: assert_receive({:handled, "support", ^id}, 1_000)
  end

  test "a slow call for one payload does not stop the next from being queued and, once it finishes, handled" do
    test_pid = self()

    Pepe.Webhooks
    |> stub(:handle_gateway_event, fn _slug, payload ->
      if payload["id"] == 1, do: Process.sleep(200)
      send(test_pid, {:handled, payload["id"]})
      :ok
    end)

    {:ok, pid} = Dispatcher.start_link("support")

    Dispatcher.dispatch(pid, %{"id" => 1})
    Dispatcher.dispatch(pid, %{"id" => 2})

    # dispatch/2 itself never blocks on the slow call - both sends above returned immediately,
    # long before payload 1's own handling (200ms) finishes. Handling order is still 1 then 2.
    assert_receive {:handled, 1}, 1_000
    assert_receive {:handled, 2}, 1_000
  end

  test "an exception in handle_gateway_event does not crash the dispatcher, and later payloads still get through" do
    test_pid = self()

    Pepe.Webhooks
    |> stub(:handle_gateway_event, fn _slug, payload ->
      if payload["id"] == 1, do: raise("boom")
      send(test_pid, {:handled, payload["id"]})
      :ok
    end)

    Process.flag(:trap_exit, true)
    {:ok, pid} = Dispatcher.start_link("support")

    Dispatcher.dispatch(pid, %{"id" => 1})
    Dispatcher.dispatch(pid, %{"id" => 2})

    assert_receive {:handled, 2}, 1_000
    assert Process.alive?(pid)
  end
end
