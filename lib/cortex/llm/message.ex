defmodule Cortex.LLM.Message do
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
end
