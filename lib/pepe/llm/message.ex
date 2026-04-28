defmodule Pepe.LLM.Message do
  @moduledoc "Constructors for OpenAI chat-completions messages."

  def system(content), do: %{"role" => "system", "content" => content}
  def user(content), do: %{"role" => "user", "content" => content}
  def assistant(content), do: %{"role" => "assistant", "content" => content || ""}

  @doc "An assistant turn that requested one or more tool calls."
  def assistant_tool_calls(content, tool_calls) do
    %{
      "role" => "assistant",
      "content" => content || "",
      "tool_calls" => tool_calls
    }
  end

  @doc "A tool result, replying to a specific tool_call id."
  def tool_result(tool_call_id, name, content) do
    %{
      "role" => "tool",
      "tool_call_id" => tool_call_id,
      "name" => name,
      "content" => content
    }
  end

  @doc """
  Repair a replayed history before it goes back to the model. If the process died
  after the model asked for tool calls but before their results were saved, the
  history ends with an `assistant` turn whose `tool_calls` have no matching `tool`
  answers, and the model would just re-issue the same call, looping forever. This
  drops any `assistant` turn whose tool calls aren't fully answered, plus any orphan
  `tool` results left pointing at a turn that was dropped.
  """
  def sanitize_replay(messages) when is_list(messages) do
    answered =
      for %{"role" => "tool", "tool_call_id" => id} <- messages, is_binary(id), into: MapSet.new(), do: id

    kept =
      Enum.filter(messages, fn
        %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
          Enum.all?(calls, fn c -> MapSet.member?(answered, c["id"]) end)

        _ ->
          true
      end)

    valid_ids =
      for %{"role" => "assistant", "tool_calls" => calls} <- kept,
          is_list(calls),
          c <- calls,
          into: MapSet.new(),
          do: c["id"]

    Enum.reject(kept, fn
      %{"role" => "tool", "tool_call_id" => id} -> not MapSet.member?(valid_ids, id)
      _ -> false
    end)
  end
end
