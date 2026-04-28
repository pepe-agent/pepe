defmodule Pepe.Agent.RuntimeTest do
  use ExUnit.Case, async: true

  alias Pepe.Agent.Runtime
  alias Pepe.LLM.Message

  defp call(name, args), do: %{"id" => "x", "function" => %{"name" => name, "arguments" => args}}
  defp turn(name, args), do: Message.assistant_tool_calls("", [call(name, args)])

  describe "stuck?/2" do
    test "flags the same tool call repeated to the threshold" do
      prior = [turn("bash", "{\"cmd\":\"x\"}"), turn("bash", "{\"cmd\":\"x\"}")]
      assert Runtime.stuck?([call("bash", "{\"cmd\":\"x\"}")], prior)
    end

    test "does not flag a couple of repeats below the threshold" do
      prior = [turn("bash", "{\"cmd\":\"x\"}")]
      refute Runtime.stuck?([call("bash", "{\"cmd\":\"x\"}")], prior)
    end

    test "different arguments are not the same call" do
      prior = [turn("bash", "{\"cmd\":\"x\"}"), turn("bash", "{\"cmd\":\"x\"}")]
      refute Runtime.stuck?([call("bash", "{\"cmd\":\"y\"}")], prior)
    end

    test "a fresh history is never stuck" do
      refute Runtime.stuck?([call("bash", "{}")], [])
    end
  end
end
