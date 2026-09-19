defmodule Pepe.ACP.Replay do
  @moduledoc """
  Turn a saved conversation back into the `session/update` notifications an editor needs
  to rebuild its panel, for `session/load`.

  The history Pepe keeps is the model's own transcript: a system prompt, user messages,
  assistant messages that may carry tool calls, and one `tool` message per call. An
  editor's panel shows something else, a thread of what the person said, what the agent
  answered, and each tool call with its outcome. This module is that translation, and
  nothing else: no IO, no state, so it is testable on a list of maps.

  What is shown, and what is left out on purpose:

    * a user message is replayed as what the person **typed**. Pepe wraps some turns in
      its own `<system-reminder>` notes (the current time, who is speaking, a compaction
      summary); those are scaffolding the person never saw, so a message that is only
      that is dropped, and one that carries a note before real text is replayed as the
      text alone.
    * an assistant message is its text, then one `tool_call` per call it made.
    * a `tool` message closes the call it answers, `completed` or `failed`. Long
      outputs are cut (the editor is showing a transcript, not the raw payload).
    * a call with no result on record, which is what an interrupted turn leaves behind,
      is closed as `failed` rather than left spinning forever.
    * the system prompt is never replayed.
  """

  alias Pepe.ACP.Protocol
  alias Pepe.Tools

  @max_output 8_000

  @doc "The ordered `session/update` payloads (not yet wrapped in notifications) for `messages`."
  @spec updates([map()]) :: [map()]
  def updates(messages) when is_list(messages) do
    {updates, open} = Enum.reduce(messages, {[], []}, &step/2)

    # Whatever is still open never got a result.
    closing = for id <- Enum.reverse(open), do: Protocol.tool_call_update(id, "failed", "No result was recorded for this call.")
    Enum.reverse(updates) ++ closing
  end

  # `open` is the ids of tool calls announced and not yet answered, newest first.
  defp step(%{"role" => "user"} = message, {updates, open}) do
    case user_text(message["content"]) do
      "" -> {updates, open}
      text -> {[Protocol.user_message_chunk(text) | updates], open}
    end
  end

  defp step(%{"role" => "assistant"} = message, {updates, open}) do
    text = assistant_text(message["content"])
    calls = for %{"id" => id} = call <- List.wrap(message["tool_calls"]), is_binary(id), do: call

    updates = if text == "", do: updates, else: [Protocol.message_chunk(text) | updates]

    Enum.reduce(calls, {updates, open}, fn call, {acc, ids} ->
      name = get_in(call, ["function", "name"]) || "tool"
      args = get_in(call, ["function", "arguments"])
      {[Protocol.tool_call(call["id"], name, args) | acc], [call["id"] | ids]}
    end)
  end

  defp step(%{"role" => "tool", "tool_call_id" => id} = message, {updates, open}) when is_binary(id) do
    if id in open do
      output = message["content"] |> to_text() |> truncate()
      status = if Tools.error?(output), do: "failed", else: "completed"
      {[Protocol.tool_call_update(id, status, output) | updates], List.delete(open, id)}
    else
      {updates, open}
    end
  end

  # The system prompt, and anything else that is not part of the visible thread.
  defp step(_other, acc), do: acc

  # The text of a user turn, without Pepe's own scaffolding around it.
  defp user_text(content) when is_binary(content), do: content |> strip_notes() |> String.trim()

  defp user_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> strip_notes(text)
      %{"type" => type} when is_binary(type) -> "[#{type}]"
      _other -> ""
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp user_text(_other), do: ""

  defp strip_notes(text), do: String.replace(text, ~r/\A(?:\s*<system-reminder>.*?<\/system-reminder>)+/s, "")

  defp assistant_text(content) when is_binary(content), do: String.trim(content)
  defp assistant_text(_other), do: ""

  defp to_text(content) when is_binary(content), do: content
  defp to_text(nil), do: ""
  defp to_text(other), do: inspect(other)

  defp truncate(text) do
    if String.length(text) > @max_output,
      do: String.slice(text, 0, @max_output) <> "\n... (output cut for the transcript)",
      else: text
  end
end
