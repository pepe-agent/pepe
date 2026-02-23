defmodule Pepe.Tools.Docs do
  @moduledoc """
  Read Pepe's own documentation - the authoritative source for **how Pepe works**
  (configuring agents, channels, scheduled tasks, MCP servers, permissions, ...).

  Before figuring out how to configure or operate Pepe, the agent should read the
  relevant doc rather than guess. Read-only, so it never needs authorization.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "docs"

  @impl true
  def spec do
    function(
      "docs",
      "Read Pepe's own how-to docs - the authoritative source for how Pepe works (agents, channels, cron, MCP, permissions, config). Pass a doc `name` from the list in your context to read it; omit `name` to list the available docs. Read these before configuring or operating Pepe.",
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
    case Pepe.Docs.read(name) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, "no doc named #{name}. Available: #{names()}"}
    end
  end

  def run(_args, _ctx), do: {:ok, "Available docs:\n" <> listing()}

  defp listing do
    case Pepe.Docs.list() do
      [] -> "(none)"
      docs -> Enum.map_join(docs, "\n", fn {name, title} -> "- #{name}: #{title}" end)
    end
  end

  defp names, do: Pepe.Docs.list() |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
end
