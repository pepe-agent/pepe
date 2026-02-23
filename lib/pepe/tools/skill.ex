defmodule Pepe.Tools.Skill do
  @moduledoc "Read a skill - an on-demand instruction doc that teaches the agent a procedure."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "skill"

  @impl true
  def spec do
    function(
      "skill",
      "Read a skill: a step-by-step instruction doc. Use it when the user asks for something a listed skill covers (e.g. installing a tool) - read the skill, then follow it. Pass the skill `name` from the list in your context.",
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The skill name to read."}
        },
        "required" => ["name"]
      }
    )
  end

  @impl true
  def run(%{"name" => name}, _ctx) when is_binary(name) do
    case Pepe.Skills.read(name) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, "no skill named #{name}"}
    end
  end

  def run(_args, _ctx), do: {:error, "missing 'name'"}
end
