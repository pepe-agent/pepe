defmodule Pepe.Agent.LoopGuard do
  @moduledoc """
  Notice when an agent is spinning instead of working, and stop it before it spends the whole
  iteration budget (and your money) going nowhere.

  Two shapes of "going nowhere", and they are different failures:

    * **Repetition.** The same tool call, same arguments, issued over and over. A command that
      fails and the model will not stop retrying; a page fetched again and again. The signal
      is that one call keeps recurring.

    * **Oscillation.** The model flip-flops between exactly two actions and never converges:
      write the file to A, test, fail, write it to B, test, fail, write it back to A. Each
      call on its own looks like progress, so plain repetition detection never fires. A/B/A/B
      is the tell, and three or more distinct actions is the opposite of a loop, it is the
      model actually exploring, so that is deliberately left alone.

  Both are pure, deterministic functions over the tool calls the model has made, computed by
  hashing (tool name + arguments). No model call, no embedding, nothing to configure: a loop
  guard that needed a model to decide would be one more thing to loop on.

  On a hit, the runtime drops the turn to its terminal branch, which strips the tools away and
  makes the model summarise what it has instead of asking for yet another turn.
  """

  # The same call this many times running means it is not going to work the next time either.
  @repeat 3

  # Look this far back for an A/B flip-flop, and call it a loop at this many alternating steps.
  # Four is two full round trips: enough to be a pattern rather than the model trying one thing,
  # reconsidering, and trying the other once, which is just deciding.
  @window 6
  @oscillate 4

  @doc """
  Is the agent stuck? `tool_calls` is what it is about to do this turn; `prior` is the message
  history it has already produced. True when adding this turn tips it into a repetition or an
  oscillation.
  """
  @spec stuck?([map()], [map()]) :: boolean()
  def stuck?(tool_calls, prior) do
    seq = signatures(prior) ++ Enum.map(tool_calls, &signature/1)
    repeating?(seq) or oscillating?(seq)
  end

  # The signatures the model has issued, oldest to newest, in the order it issued them. Order
  # is the whole point for oscillation, so this keeps the sequence rather than counting.
  defp signatures(messages) do
    for %{"role" => "assistant", "tool_calls" => calls} <- messages,
        is_list(calls),
        call <- calls do
      signature(call)
    end
  end

  # The last @repeat calls are all the same call. Consecutive on purpose: a tool used three
  # times across a long task, with real work between, is not a loop, and flagging it would
  # teach people the guard cries wolf. It is the *unbroken* run that means it is stuck.
  defp repeating?(seq) do
    tail = Enum.take(seq, -@repeat)
    Enum.count(tail) == @repeat and match?([_], Enum.uniq(tail))
  end

  # The recent calls alternate between exactly two signatures. Two distinct values and every
  # neighbour different is A/B/A/B by construction; a third distinct value breaks it, and that
  # is the model exploring rather than stuck.
  defp oscillating?(seq) do
    window = Enum.take(seq, -@window)

    Enum.count(window) >= @oscillate and
      match?([_, _], Enum.uniq(window)) and
      alternating?(window)
  end

  defp alternating?(seq) do
    seq
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> a != b end)
  end

  defp signature(%{"function" => %{"name" => name, "arguments" => args}}), do: {name, args}
  defp signature(_), do: :unknown
end
