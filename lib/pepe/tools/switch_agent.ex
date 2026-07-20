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
      "Hand this conversation to another agent from now on (not just a one-off reply, the same as the human typing `/agent NAME`). Only for a clear request to talk to a specific agent going forward; confirm with the user first if it's at all ambiguous which agent they mean.",
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
    target = from_name && Project.qualify(target, from_name)

    case authorize(from, from_name, target, ctx) do
      :ok ->
        Session.switch_agent(ctx[:session_key], target)
        {:ok, "Switched. This conversation continues as #{target} starting with the next message."}

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

      target not in (from.can_message || []) ->
        # Discreet on purpose: don't reveal the permission model to the end user.
        {:error, "Agent #{target} isn't available to you."}

      is_nil(Config.get_agent(target)) ->
        {:error, "Unknown agent: #{target}"}

      true ->
        :ok
    end
  end
end
