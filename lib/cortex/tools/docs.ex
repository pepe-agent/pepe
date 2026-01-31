defmodule Cortex.Tools.Docs do
  @moduledoc """
  Read Cortex's own documentation — the authoritative source for **how Cortex works**
  (configuring agents, channels, scheduled tasks, MCP servers, permissions, …).

  Before figuring out how to configure or operate Cortex, the agent should read the
  relevant doc rather than guess. Read-only, so it never needs authorization.
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "docs"

  @impl true
  def spec do
    function(
      "docs",
      "Read Cortex's own how-to docs — the authoritative source for how Cortex works (agents, channels, cron, MCP, permissions, config). Pass a doc `name` from the list in your context to read it; omit `name` to list the available docs. Read these before configuring or operating Cortex.",
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The doc name to read (omit to list)."}
        }
      }
    )
  end

  @impl true
  def run(%{"name" => name}, _ctx) when is_binary(name) and name != "" do
    case Cortex.Docs.read(name) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, "no doc named #{name}. Available: #{names()}"}
    end
  end

  def run(_args, _ctx), do: {:ok, "Available docs:\n" <> listing()}

  defp listing do
    case Cortex.Docs.list() do
      [] -> "(none)"
      docs -> Enum.map_join(docs, "\n", fn {name, title} -> "- #{name}: #{title}" end)
    end
  end

  defp names, do: Cortex.Docs.list() |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
end
