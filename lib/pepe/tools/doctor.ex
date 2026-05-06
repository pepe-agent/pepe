defmodule Pepe.Tools.Doctor do
  @moduledoc """
  Run the health checks (`Pepe.Doctor`) from chat - the agent's way to **verify**
  something worked after changing it (a new bot, MCP server, cron, model). Read-only.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "doctor"

  @impl true
  def spec do
    function(
      "doctor",
      "Health-check the whole Pepe setup and report what's broken: unset ${ENV} secrets, agents pointing at missing models, invalid cron schedules, unreachable Telegram bots / model connections / MCP servers. Run it after you change something to confirm it works. Pass live: true to also probe the network (slower).",
      %{
        "type" => "object",
        "properties" => %{
          "live" => %{
            "type" => "boolean",
            "description" => "Also probe Telegram/models/MCP over the network (default false)."
          }
        }
      }
    )
  end

  @impl true
  def run(args, _ctx) do
    # `checks/1` always returns at least the checks that need no config, so there is no
    # empty case to handle: a clause for one would be dead code, and Dialyzer says so.
    checks = Pepe.Doctor.checks(live: args["live"] == true)
    problems = Enum.reject(checks, &match?({_, _, :ok}, &1))

    summary =
      if problems == [] do
        "✅ All #{length(checks)} checks passed."
      else
        "#{length(problems)} issue(s) out of #{length(checks)} checks:\n" <>
          Enum.map_join(problems, "\n", &format/1)
      end

    {:ok, summary}
  end

  defp format({area, subject, {:error, msg}}), do: "❌ [#{area}] #{subject} - #{msg}"
  defp format({area, subject, {:warn, msg}}), do: "⚠️ [#{area}] #{subject} - #{msg}"
end
