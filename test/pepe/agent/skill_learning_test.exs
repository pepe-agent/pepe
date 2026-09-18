defmodule Pepe.Agent.SkillLearningTest do
  @moduledoc """
  What these pin is *when* the agent is invited to bring a skill up, never what it then
  says: the note is an invitation the model may decline, so the only thing worth testing
  is the bar it has to cross to be offered at all.
  """
  use ExUnit.Case, async: true

  alias Pepe.Agent.SkillLearning
  alias Pepe.LLM.Message

  @agent %{skill_learning: true, tools: ["bash", "read_file", "list_dir", "write_file", "skill"]}

  defp result(id, name, content \\ "fine"), do: Message.tool_result(id, name, content)

  defp asked(calls) do
    Message.assistant_tool_calls(nil, Enum.map(calls, fn {id, name, args} -> call(id, name, args) end))
  end

  defp call(id, name, args),
    do: %{"id" => id, "type" => "function", "function" => %{"name" => name, "arguments" => Jason.encode!(args)}}

  # A turn of N successful calls spread over two tools - the shape that clears the bar.
  defp busy_turn do
    [
      asked([{"1", "bash", %{}}, {"2", "read_file", %{}}, {"3", "bash", %{}}, {"4", "list_dir", %{}}]),
      result("1", "bash"),
      result("2", "read_file"),
      result("3", "bash"),
      result("4", "list_dir")
    ]
  end

  defp note(agent, messages) do
    case SkillLearning.reminders(agent, messages) do
      [] -> nil
      [%{"role" => "user", "content" => text}] -> text
    end
  end

  describe "offering to save a new skill" do
    test "a turn with enough work across enough tools earns the offer" do
      text = note(@agent, [Message.user("do the thing")] ++ busy_turn())

      assert text =~ "<system-reminder>"
      assert text =~ "offering to save it as a skill"
      assert text =~ "skill-creator"
      # An invitation, not an instruction to go write something.
      assert text =~ "without an explicit yes"
    end

    test "off by default: the same turn earns nothing without the flag" do
      assert note(%{@agent | skill_learning: false}, [Message.user("go")] ++ busy_turn()) == nil
      assert note(Map.delete(@agent, :skill_learning), [Message.user("go")] ++ busy_turn()) == nil
    end

    test "a short turn is not a procedure" do
      turn = [
        asked([{"1", "bash", %{}}, {"2", "read_file", %{}}, {"3", "bash", %{}}]),
        result("1", "bash"),
        result("2", "read_file"),
        result("3", "bash")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end

    test "the same tool over and over is a retry loop, not a procedure" do
      turn = [
        asked([{"1", "bash", %{}}, {"2", "bash", %{}}, {"3", "bash", %{}}, {"4", "bash", %{}}, {"5", "bash", %{}}]),
        result("1", "bash"),
        result("2", "bash"),
        result("3", "bash"),
        result("4", "bash"),
        result("5", "bash")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end

    test "failed calls don't count toward the bar" do
      turn = [
        asked([{"1", "bash", %{}}, {"2", "read_file", %{}}, {"3", "bash", %{}}, {"4", "list_dir", %{}}]),
        result("1", "bash"),
        result("2", "read_file", "Error: read_file failed: enoent"),
        result("3", "bash", "Error: tool bash crashed: boom"),
        result("4", "list_dir")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end

    test "only the turn in progress counts, not the busy one before it" do
      history = [Message.user("earlier")] ++ busy_turn() ++ [Message.assistant("done")]

      assert note(@agent, history ++ [Message.user("and now a quick question")]) == nil
    end

    test "an agent that cannot write a file is never offered the chance" do
      agent = %{@agent | tools: ["bash", "read_file", "list_dir", "skill"]}

      assert note(agent, [Message.user("go")] ++ busy_turn()) == nil
    end
  end

  # A turn that opened the named skill and then ran the given tools, each with its own
  # result - the second half of the tuple is what came back, so a test can make one fail.
  defp followed_skill(name, results) do
    calls = [{"s", "skill", %{"name" => name}}] ++ Enum.map(results, fn {id, tool, _} -> {id, tool, %{}} end)

    [asked(calls), result("s", "skill")] ++ Enum.map(results, fn {id, tool, content} -> result(id, tool, content) end)
  end

  describe "offering to correct a skill that was followed" do
    test "a skill read, then a failure, proposes an edit to that skill by name" do
      turn = followed_skill("cut-a-release", [{"1", "bash", "fine"}, {"2", "bash", "Error: tool bash crashed: no such target"}])

      text = note(@agent, [Message.user("cut a release")] ++ turn)

      assert text =~ "You read the `cut-a-release` skill"
      assert text =~ "An edit to that skill, never a new one"
      assert text =~ "Edit / audit / tidy"
      # The two halves are mutually exclusive: a skill that already exists gets corrected,
      # it does not get written a second time under a new name.
      refute text =~ "offering to save it as a skill"
    end

    test "a skill that was followed and worked teaches nothing, so nothing is offered" do
      turn = followed_skill("cut-a-release", [{"1", "bash", "fine"}, {"2", "bash", "fine"}])

      assert note(@agent, [Message.user("cut a release")] ++ turn) == nil
    end

    test "a busy turn that consulted a skill never turns into a NEW skill offer" do
      turn = [
        asked([{"s", "skill", %{"name" => "cut-a-release"}}, {"1", "bash", %{}}, {"2", "read_file", %{}}, {"3", "list_dir", %{}}]),
        result("s", "skill"),
        result("1", "bash"),
        result("2", "read_file"),
        result("3", "list_dir")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end

    test "a failure BEFORE the skill was read is not evidence against it" do
      turn = [
        asked([{"1", "bash", %{}}, {"s", "skill", %{"name" => "cut-a-release"}}]),
        result("1", "bash", "Error: tool bash crashed: boom"),
        result("s", "skill")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end

    test "a skill that doesn't exist is not a skill to correct" do
      turn = [
        asked([{"s", "skill", %{"name" => "nope"}}, {"1", "bash", %{}}]),
        result("s", "skill", "Error: no skill named nope"),
        result("1", "bash", "Error: tool bash crashed: boom")
      ]

      assert note(@agent, [Message.user("go")] ++ turn) == nil
    end
  end
end
