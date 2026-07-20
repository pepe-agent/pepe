defmodule Pepe.Tools.SwitchAgent do
  @moduledoc """
  Hand this whole conversation to another agent, from now on: not a one-off reply
  like `send_to_agent`. Use it when the user is asking to talk to a specific agent
  going forward ("connect me with the Engineer", "let me talk to support directly"),
  the same thing `/agent NAME` does when a human types it, but reachable from plain
  language instead of the slash command.

  Authorization mirrors `send_to_agent`'s: a directed allowlist (`can_message`) plus
  the same-project boundary: an agent can only switch a conversation to a peer it's
  already allowed to route to.

  The switch takes effect **after this turn**, not mid-reply: the human still gets
  this turn's answer from the agent that's already talking to them (so it can say
  "sure, connecting you now"), and the very next message is the first one the new
  agent sees, with a fresh context: the same behavior `/agent NAME` already has.
  Doing it any earlier would rebind the conversation out from under this turn's own
  run while it's still using it.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Session
  alias Pepe.Config
  alias Pepe.Project

  @impl true
  def name, do: "switch_agent"

  @impl true
  def spec do
    function(
      "switch_agent",
      "Hand this conversation to another agent from now on (not just a one-off reply, the same as the human typing `/agent NAME`). Use this whenever the user asks to be connected, transferred, or put in touch with a specific agent (\"connect me with X\", \"conecte com o agente X\", \"let me talk to X\"). Do not substitute send_to_agent for this and then describe the user as connected; they are not until this tool has run. Confirm with the user first if it's at all ambiguous which agent they mean.",
      %{
        "type" => "object",
        "properties" => %{
          "target" => %{"type" => "string", "description" => "The agent to hand the conversation to."}
        },
        "required" => ["target"]
      }
    )
  end

  @impl true
  def run(%{"target" => target}, ctx) when is_binary(target) do
    from = ctx[:agent]
    from_name = from && from.name
    qualified = from_name && Project.qualify(target, from_name)

    case authorize(from, from_name, qualified, ctx) do
      {:ok, resolved} ->
        Session.switch_agent(ctx[:session_key], resolved)
        Pepe.Gateways.Telegram.persist_agent_binding(ctx[:session_key], resolved)

        {:ok,
         "Switched to #{resolved}. This conversation continues as #{resolved} starting with the next message. If you name the agent to the user, use this exact spelling and capitalization: #{resolved}."}

      {:error, _} = err ->
        err
    end
  end

  def run(_args, _ctx), do: {:error, "switch_agent needs `target`"}

  defp authorize(from, from_name, target, ctx) do
    cond do
      is_nil(from) ->
        {:error, "no calling agent in context"}

      is_nil(ctx[:session_key]) ->
        {:error, "no session to switch: this only works inside a real conversation"}

      not Project.same_scope?(target, from_name) ->
        {:error, "Refusing to switch to #{target}: it belongs to a different project."}

      true ->
        case find_allowed(target, from.can_message || []) do
          # Discreet on purpose: don't reveal the permission model to the end user.
          nil -> {:error, "Agent #{target} isn't available to you."}
          resolved -> check_exists(resolved, target)
        end
    end
  end

  defp check_exists(resolved, target) do
    if Config.get_agent(resolved), do: {:ok, resolved}, else: {:error, "Unknown agent: #{target}"}
  end

  # A model-typed target ("engenheiro") deserves the same case leeway a human gets from
  # `/agent engenheiro` finding "Engenheiro": match `can_message` (already in each agent's
  # exact-case canonical handle) case-insensitively, and use ITS value from here on, rather
  # than re-deriving a canonical form independently (which can disagree on how the root/
  # default scope is prefixed; see `Pepe.Config`'s `agent_handle/2` vs `Pepe.Project.qualify/2`).
  defp find_allowed(target, allowed) do
    Enum.find(allowed, &(String.downcase(&1) == String.downcase(target)))
  end
end
