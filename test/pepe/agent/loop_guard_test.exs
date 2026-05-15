defmodule Pepe.Agent.LoopGuardTest do
  @moduledoc """
  The guard has to catch a spinning agent without stopping a working one. Both halves are
  pinned: the repetition case (the same call over and over) and the oscillation case (A/B/A/B),
  and next to each the shape that looks similar but is real progress and must be left alone.
  """
  use ExUnit.Case, async: true

  alias Pepe.Agent.LoopGuard
  alias Pepe.LLM.Message

  defp call(name, args), do: %{"id" => "x", "function" => %{"name" => name, "arguments" => args}}
  defp turn(name, args), do: Message.assistant_tool_calls("", [call(name, args)])
  defp bash(cmd), do: call("bash", ~s({"cmd":"#{cmd}"}))
  defp bash_turn(cmd), do: turn("bash", ~s({"cmd":"#{cmd}"}))

  describe "repetition" do
    test "the same call, three in a row, is stuck" do
      prior = [bash_turn("x"), bash_turn("x")]
      assert LoopGuard.stuck?([bash("x")], prior)
    end

    test "two in a row is not enough" do
      assert LoopGuard.stuck?([bash("x")], [bash_turn("x")]) == false
    end

    test "different arguments are a different call" do
      prior = [bash_turn("x"), bash_turn("x")]
      refute LoopGuard.stuck?([bash("y")], prior)
    end

    test "the same tool three times but not in a row is not stuck" do
      # Reading a file at three points of a long task, with real work in between, is not a
      # loop. Flagging it would teach people the guard cries wolf. It is the unbroken run that
      # means stuck, so this must stay quiet.
      prior = [bash_turn("read a"), bash_turn("write b"), bash_turn("read a"), bash_turn("write c")]
      refute LoopGuard.stuck?([bash("read a")], prior)
    end

    test "a fresh history is never stuck" do
      refute LoopGuard.stuck?([bash("x")], [])
    end
  end

  describe "oscillation" do
    test "flip-flopping between exactly two calls is stuck" do
      # Write the file to A, test, write it to B, test, back to A... each call looks like
      # progress on its own, which is why plain repetition detection never catches this.
      prior = [bash_turn("set A"), bash_turn("set B"), bash_turn("set A")]
      assert LoopGuard.stuck?([bash("set B")], prior)
    end

    test "one round trip is not yet a loop, it is deciding" do
      # A, then B, then A once more: the model tried one thing, reconsidered, went back. That
      # is a decision, not a loop, and calling it a loop would cut off normal course-correction.
      prior = [bash_turn("set A"), bash_turn("set B")]
      refute LoopGuard.stuck?([bash("set A")], prior)
    end

    test "three distinct actions is exploring, not oscillating" do
      # The moment there is a third value, it is not a two-state flip-flop. That is the model
      # actually working through options, and it is exactly what must not be interrupted.
      prior = [bash_turn("A"), bash_turn("B"), bash_turn("C")]
      refute LoopGuard.stuck?([bash("A")], prior)
    end

    test "alternation that has since moved on is not stuck" do
      # It flip-flopped, then broke out and did something new. The window has moved past the
      # loop, so the guard should have too.
      prior = [bash_turn("A"), bash_turn("B"), bash_turn("A"), bash_turn("B"), bash_turn("A")]
      refute LoopGuard.stuck?([bash("C")], prior)
    end

    test "the oscillation can span more than one tool" do
      # read_file(x) then write_file(y), over and over: read what you just wrote, write it
      # again. Two distinct signatures alternating, across two different tools.
      prior = [turn("read_file", ~s({"p":"x"})), turn("write_file", ~s({"p":"y"})), turn("read_file", ~s({"p":"x"}))]
      assert LoopGuard.stuck?([call("write_file", ~s({"p":"y"}))], prior)
    end
  end
end
