defmodule Pepe.Tools.SetRoute do
  @moduledoc """
  Add or remove a **directed** agent-to-agent route — change who may message whom.

  This is how the agent reconfigures routing from chat. `from` defaults to the
  calling agent; `action` is `"allow"` (add the route) or `"deny"` (remove it).
  Routing is directed, so allowing `A → B` does not allow `B → A`. Because it edits
  config, it goes through the permission gate like other config-changing tools — the
  user authorizes the change. Pairs with the `manage-routing` skill.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Config

  @impl true
  def name, do: "set_route"

  @impl true
  def spec do
    function(
      "set_route",
      "Allow or remove a directed agent-to-agent route (who can message whom). `from` defaults to you; `action` is \"allow\" (add) or \"deny\" (remove). Directed: allowing A→B does not allow B→A.",
      %{
        "type" => "object",
        "properties" => %{
          "from" => %{"type" => "string", "description" => "Sender agent (defaults to you)."},
          "to" => %{"type" => "string", "description" => "Recipient agent."},
          "action" => %{
            "type" => "string",
            "enum" => ["allow", "deny"],
            "description" => "allow = add the route, deny = remove it (default allow)."
          }
        },
        "required" => ["to"]
      }
    )
  end

  @impl true
  def run(args, ctx) do
    from = args["from"] || (ctx[:agent] && ctx[:agent].name)
    to = args["to"]
    action = args["action"] || "allow"

    cond do
      is_nil(from) -> {:error, "no `from` agent (and none in context)"}
      not is_binary(to) -> {:error, "`to` is required"}
      is_nil(Config.get_agent(from)) -> {:error, "Unknown agent: #{from}"}
      is_nil(Config.get_agent(to)) -> {:error, "Unknown agent: #{to}"}
      action == "deny" -> remove(from, to)
      true -> add(from, to)
    end
  end

  defp add(from, to) do
    Config.allow_message(from, to)
    {:ok, "#{from} can now message #{to}."}
  end

  defp remove(from, to) do
    Config.disallow_message(from, to)
    {:ok, "Removed route #{from} → #{to}."}
  end
end
