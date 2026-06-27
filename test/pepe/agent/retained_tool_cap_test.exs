defmodule Pepe.Agent.RetainedToolCapTest do
  @moduledoc """
  A big tool result (a 20KB file read, a noisy command) must NOT sit whole in the retained
  history: a later short follow-up ("which are they?") would otherwise be drowned by stale tool
  bulk, and the model binds the ambiguous question to the biggest recent blob instead of the
  one-line answer. Retained tool results keep a head + tail; everything else is untouched.
  """
  use ExUnit.Case, async: true

  alias Pepe.Agent.Session

  test "a large tool result is elided (head + tail) in retained history" do
    big = String.duplicate("x", 20_000)

    messages = [
      %{"role" => "system", "content" => "you are helpful"},
      %{"role" => "user", "content" => "quantas empresas?"},
      %{"role" => "assistant", "content" => "Temos 6 empresas."},
      %{"role" => "tool", "tool_call_id" => "c1", "content" => big}
    ]

    [_sys, _user, _assistant, tool] = Session.cap_retained_tool_results(messages)

    assert byte_size(tool["content"]) < byte_size(big)
    assert tool["content"] =~ "middle elided from history"
    # The head is kept so the agent still remembers what the tool did.
    assert String.starts_with?(tool["content"], "xxxx")
  end

  test "small tool results and non-tool messages pass through untouched" do
    messages = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => "hi"},
      %{"role" => "assistant", "content" => String.duplicate("a", 20_000)},
      %{"role" => "tool", "tool_call_id" => "c1", "content" => "6"}
    ]

    assert Session.cap_retained_tool_results(messages) == messages
  end
end
