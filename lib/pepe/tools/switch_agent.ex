defmodule Pepe.Tools.SwitchAgent do
  @moduledoc """
  Hand this whole conversation to another agent, for now: not a one-off reply like
  `send_to_agent`, but not a lasting change to the channel's own setup either. Use it
  when the user is asking to talk to a specific agent going forward ("connect me with
  the Engineer", "let me talk to support directly") - it lasts for this conversation,
  until `/new` hands it back to whichever agent this channel actually starts with.

  For a *lasting* handoff - "this channel is always the Engineer's from now on" - that
  is `manage_channel`'s `bind_topic` action (or a human typing `/agent NAME`), never
  this one: it changes the channel's own configuration, kept across `/new` and
  restarts, which is a different kind of decision than routing one conversation right
  now. Do not use this tool for that; say it isn't available and point at the
  permanent option, or ask which one the user actually means if it's ambiguous.

  Authorization mirrors `send_to_agent`'s: a directed allowlist (`can_message`) plus
  the same-project boundary: an agent can only switch a conversation to a peer it's
  already allowed to route to.

  The switch takes effect **after this turn**, not mid-reply: the human still gets
  this turn's answer from the agent that's already talking to them (so it can say
  "sure, connecting you now"), and the very next message is the first one the new
  agent sees, with a fresh context. Doing it any earlier would rebind the
  conversation out from under this turn's own run while it's still using it.
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
      "Hand THIS CONVERSATION to another agent, for now - lasts until /new, not a lasting change to the channel. Use this whenever the user asks to be connected, transferred, or put in touch with a specific agent right now (\"connect me with X\", \"conecte com o agente X\", \"let me talk to X\"). Do NOT use this when the user asks for a LASTING change (\"from now on this channel is always X\", \"a partir de agora esse canal é sempre o agente X\", \"permanently route this to X\") - that is `manage_channel`'s `bind_topic` action instead, a config change that survives /new and restarts. Do not substitute send_to_agent for this and then describe the user as connected; they are not until this tool has run. Confirm with the user first if it's at all ambiguous which agent they mean, or whether they want this or the permanent kind.",
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
