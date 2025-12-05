defmodule Cortex.Tools.EnableTool do
  @moduledoc "Let the agent add a tool to its own allowlist (e.g. after installing a plugin)."
  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Config

  @impl true
  def name, do: "enable_tool"

  @impl true
  def spec do
    function(
      "enable_tool",
      "Add a tool to your own allowlist so you can start using it — e.g. right after installing a plugin under plugins/. Pass the tool's `name` (it must already exist as a built-in or a plugin). Takes effect on your next message.",
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The tool name to enable."}
        },
        "required" => ["name"]
      }
    )
  end

  @impl true
  def run(%{"name" => tool}, ctx) when is_binary(tool) and tool != "" do
    with %{name: agent_name} <- ctx[:agent],
         %{} = agent <- Config.get_agent(agent_name) do
      cond do
        is_nil(Cortex.Tools.get(tool)) ->
          {:error, "no tool named #{tool} (it must exist as a built-in or a plugin first)"}

        tool in (agent.tools || []) ->
          {:ok, "#{tool} is already enabled"}

        true ->
          Config.put_agent(%{agent | tools: Enum.uniq((agent.tools || []) ++ [tool])})
          {:ok, "enabled #{tool}; you can use it from your next message"}
      end
    else
      _ -> {:error, "no bound agent to update"}
    end
  end

  def run(_args, _ctx), do: {:error, "missing 'name'"}
end
