defmodule Cortex.Tools.ScanSkill do
  @moduledoc """
  Run the static security scanner (`Cortex.Skills.Sentinel`) over skill text before
  installing it — a programmatic second check alongside the agent's own read-through.
  Read-only (never installs anything itself).
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "scan_skill"

  @impl true
  def spec do
    function(
      "scan_skill",
      "Security-scan skill Markdown text before installing it (fetched from a URL or elsewhere). Flags prompt injection, secret exfiltration, destructive commands, persistence, and obfuscation. Use before write_file'ing a new skill from an external source. This is a second check, not a replacement for reading the content yourself.",
      %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "description" => "The skill's full Markdown text."}
        },
        "required" => ["content"]
      }
    )
  end

  @impl true
  def run(%{"content" => content}, _ctx) when is_binary(content) do
    {:ok, Cortex.Skills.Sentinel.scan(content) |> Cortex.Skills.Sentinel.report()}
  end

  def run(_args, _ctx), do: {:error, "scan_skill needs `content`"}
end
