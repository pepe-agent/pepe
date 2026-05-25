defmodule Pepe.LLM.OutputCap do
  @moduledoc """
  Read back, from a provider's own refusal, how much room is left for the answer.

  There is a 400 that looks like a context overflow and is not. The conversation fits; what
  does not fit is `input + max_tokens`, the *reservation for the answer*. Trimming the
  history cannot fix it, because the window never shrank. A runtime that mistakes it for an
  overflow condenses the conversation, re-sends with the same oversized `max_tokens`, and
  is refused in exactly the same way, forever. The loop is not a race and not bad luck: it
  is deterministic, and it ends when the retry budget runs out and the turn dies.

  The fix is to lower the reservation, and the provider has already said how far: every
  dialect below is something a real provider actually writes in its error body.

  `available/1` is the only predicate. If it returns a number, the error is one we can
  recover from, and that number is the ceiling. If it returns `nil`, it is not our case and
  the caller should treat it as any other failure. One function, so a guard elsewhere can
  never disagree with the recovery path about what this error is.
  """

  # "max_tokens: 32768 > context_window: 200000 - input_tokens: 190000 = available_tokens: 10000"
  @available ~r/available_tokens["':\s]+(\d+)/i

  # "Range of max_tokens should be [1, 65536]" - the ceiling is the model's own output cap,
  # which says nothing about what is left in *this* window. Useful, but only as an upper bound.
  @range ~r/max_tokens\s+should\s+be\s+\[\s*\d+\s*,\s*(\d+)\s*\]/i

  # "max_tokens: 5000 > 4096, which is the maximum allowed number of output tokens" - Anthropic's
  # wording when the requested output cap exceeds the model's own maximum. The ceiling is the
  # second number. Guarded so it can't fire on the `@available` phrasing ("... > context_window:
  # 200000 ..."), where a non-digit follows the `>`.
  @exceeds ~r/max_tokens:?\s*\d+\s*>\s*(\d+)/i

  # "This model's maximum context length is 8192 tokens. However, you requested 8500 tokens
  #  (7500 in the messages, 1000 in the completion)."
  @window ~r/maximum context length is (\d+)/i
  @input ~r/(\d+)\s+(?:tokens?\s+)?(?:in the messages|of text input|of tool input|input tokens)/i

  @doc """
  How many output tokens the provider says are still available, or `nil` when this error is
  not an answer-reservation refusal at all.
  """
  @spec available(term()) :: pos_integer() | nil
  def available(body) do
    body |> text() |> parse()
  end

  defp parse(""), do: nil

  defp parse(text) do
    cond do
      n = capture(@available, text) -> n
      n = from_window(text) -> n
      n = capture(@range, text) -> n
      n = capture(@exceeds, text) -> n
      true -> nil
    end
  end

  # The window minus everything the provider counted as input. A result of zero or less
  # means the *input* is what overflowed, which is a real context overflow and none of our
  # business: say nothing and let it be handled as one.
  defp from_window(text) do
    with window when is_integer(window) <- capture(@window, text),
         [_ | _] = parts <- Regex.scan(@input, text) do
      input = parts |> Enum.map(fn [_, n] -> String.to_integer(n) end) |> Enum.sum()
      left = window - input
      if left > 0, do: left, else: nil
    else
      _ -> nil
    end
  end

  defp capture(regex, text) do
    case Regex.run(regex, text) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp text(body) when is_binary(body), do: body
  defp text(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp text(%{"error" => m}) when is_binary(m), do: m
  defp text(%{"message" => m}) when is_binary(m), do: m

  defp text(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      _ -> ""
    end
  end

  defp text(_), do: ""
end
