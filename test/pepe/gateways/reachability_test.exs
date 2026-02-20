defmodule Pepe.Gateways.ReachabilityTest do
  use ExUnit.Case, async: false

  alias Pepe.Gateways.Reachability

  test "a chat is alive until marked dead, then dead until cleared" do
    bot = "b#{System.unique_integer([:positive])}"
    refute Reachability.dead?(bot, 123)

    Reachability.mark_dead(bot, 123)
    assert Reachability.dead?(bot, 123)

    Reachability.clear(bot, 123)
    refute Reachability.dead?(bot, 123)
  end

  test "dead marks are scoped per bot" do
    a = "bot-a-#{System.unique_integer([:positive])}"
    b = "bot-b-#{System.unique_integer([:positive])}"
    Reachability.mark_dead(a, 999)

    assert Reachability.dead?(a, 999)
    refute Reachability.dead?(b, 999)
  end

  describe "permanent_failure?/1" do
    test "403 Forbidden (blocked) is permanent" do
      assert Reachability.permanent_failure?({:ok, %{status: 403}})
    end

    test "400 with a known permanent description is permanent" do
      assert Reachability.permanent_failure?(
               {:ok, %{status: 400, body: %{"description" => "Bad Request: chat not found"}}}
             )
    end

    test "other errors (rate limit, transport) are NOT permanent" do
      refute Reachability.permanent_failure?({:ok, %{status: 429}})
      refute Reachability.permanent_failure?({:error, %Req.TransportError{reason: :timeout}})
    end

    test "success is not a failure" do
      refute Reachability.permanent_failure?({:ok, %{status: 200, body: %{"ok" => true}}})
    end
  end
end
