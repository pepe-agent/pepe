defmodule Pepe.Gateways.Discord.ProtocolTest do
  @moduledoc """
  The decisions in Discord's gateway protocol that would make a bot either loop forever on a
  refusal or give up on a connection that only needed a resume: what a close code means,
  what to ask for, how long to wait. Pure, so no socket is needed to pin them down.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Pepe.Gateways.Discord.Protocol

  describe "close_action/2" do
    test "a refusal that reconnecting cannot fix stops the connection" do
      for code <- [4004, 4010, 4011, 4012, 4013] do
        assert Protocol.close_action(code, true) == :stop
        assert Protocol.close_action(code, false) == :stop
      end
    end

    test "4014 retries without the privileged intent once, then stops" do
      assert Protocol.close_action(4014, true) == :without_content
      assert Protocol.close_action(4014, false) == :stop
    end

    test "a session Discord no longer knows starts over instead of resuming" do
      assert Protocol.close_action(4007, true) == :reidentify
      assert Protocol.close_action(4009, true) == :reidentify
    end

    test "everything else, including a plain close, picks the session back up" do
      for code <- [1000, 1001, 1006, 4000, 4001, 4002, 4003, 4005, 4008, nil] do
        assert Protocol.close_action(code, true) == :resume
      end
    end

    test "every code that stops the connection explains itself" do
      for code <- [4004, 4010, 4011, 4012, 4013, 4014] do
        refute Protocol.explain(code) =~ "closed with code"
      end

      assert Protocol.explain(4014) =~ "Developer Portal"
      assert Protocol.explain(1006) == "closed with code 1006"
    end
  end

  describe "intents/1" do
    test "guild and direct messages are always asked for, Message Content only when wanted" do
      guild = 1 <<< 9
      direct = 1 <<< 12
      content = 1 <<< 15

      assert Protocol.intents(true) == (guild ||| direct ||| content)
      assert Protocol.intents(false) == (guild ||| direct)
      assert (Protocol.intents(false) &&& content) == 0
    end
  end

  describe "frames" do
    test "identify carries the token and the intents" do
      assert %{"op" => 2, "d" => %{"token" => "tok", "intents" => intents}} = Protocol.identify("tok", false)
      assert intents == Protocol.intents(false)
    end

    test "resume names the session and the last sequence seen" do
      assert Protocol.resume("tok", "sess", 42) ==
               %{"op" => 6, "d" => %{"token" => "tok", "session_id" => "sess", "seq" => 42}}
    end

    test "a heartbeat before any event carries no sequence" do
      assert Protocol.heartbeat(nil) == %{"op" => 1, "d" => nil}
      assert Protocol.heartbeat(7) == %{"op" => 1, "d" => 7}
    end

    test "decode accepts a frame and refuses anything else" do
      assert {:ok, %{"op" => 10}} = Protocol.decode(~s({"op":10,"d":{"heartbeat_interval":41250}}))
      assert Protocol.decode("not json") == :error
      assert Protocol.decode(~s({"no":"op"})) == :error
    end
  end

  describe "timing" do
    test "backoff starts near a second, doubles, and never passes a minute plus jitter" do
      assert Protocol.backoff(0) in 1_000..1_250
      assert Protocol.backoff(1) in 2_000..2_500
      assert Protocol.backoff(2) in 4_000..5_000

      for attempt <- 6..40 do
        assert Protocol.backoff(attempt) in 60_000..75_000
      end
    end

    test "the first heartbeat lands inside the interval, so a herd does not beat together" do
      for _ <- 1..50, do: assert(Protocol.first_heartbeat(40_000) in 0..40_000)
    end
  end
end
