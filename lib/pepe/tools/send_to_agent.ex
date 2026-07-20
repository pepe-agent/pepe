defmodule Pepe.Tools.SendToAgent do
  @moduledoc """
  Send a message to another agent and return its reply - the agent-to-agent router.

  Routing is a **directed allowlist**: an agent may only message the agents listed
  in its `can_message`, so `A -> B` does not imply `B -> A`. The called agent answers
  in a fresh one-shot run (it sees the message labelled with the sender), and its
  reply comes back as this tool's result - answering is not itself "messaging", so
  no reverse route is needed.

  A **hop limit** and a **cycle check** keep chains from looping: a run carries the
  chain of agents so far (in `ctx.agent_chain`), and a call is refused if the target
  is already in the chain or the chain is too deep. The route allowlist is the
  authorization here, so the call isn't put through the human permission gate; the
  callee's own risky tools still are (the `authorize` callback is inherited).
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Runtime
  alias Pepe.Project
  alias Pepe.Config

  @max_hops 5

  @impl true
  def name, do: "send_to_agent"

  @impl true
  def spec do
    function(
      "send_to_agent",
      "Send a message to another agent and get its reply, to delegate a question or consult a peer. This is a one-off: it never changes who the user is talking to. Never tell the user this connected them to the other agent or that the other agent is now handling the conversation; it isn't. If the user asked to be connected, transferred, or put in touch with a specific agent (\"connect me with X\", \"conecte com o agente X\"), that's switch_agent, not this tool.",
      %{
        "type" => "object",
        "properties" => %{
          "to" => %{"type" => "string", "description" => "Name of the agent to message."},
          "message" => %{"type" => "string", "description" => "What to say to them."}
        },
        "required" => ["to", "message"]
      }
    )
  end

  @impl true
  def run(%{"to" => to, "message" => message}, ctx)
      when is_binary(to) and is_binary(message) do
    from = ctx[:agent]
    from_name = from && from.name
    chain = ctx[:agent_chain] || List.wrap(from_name)
    # A bare target resolves to a peer in the sender's own project.
    qualified = from_name && Project.qualify(to, from_name)

    case authorize(from, from_name, qualified, chain) do
      {:ok, resolved} -> deliver(resolved, from_name, message, chain, ctx)
      {:error, _} = err -> err
    end
  end

  def run(_args, _ctx), do: {:error, "send_to_agent needs `to` and `message`"}

  defp authorize(from, from_name, to, chain) do
    cond do
      is_nil(from) ->
        {:error, "no calling agent in context"}

      # Hard tenant boundary: never route across projects, even if an allowlist or a
      # qualified handle asks for it. The route allowlist is scoped, this backs it up.
      not Project.same_scope?(to, from_name) ->
        {:error, "Refusing to message #{to}: it belongs to a different project."}

      true ->
        case find_allowed(to, from.can_message || []) do
          # Discreet on purpose: don't reveal the permission model to the end user.
          nil -> {:error, "Agent #{to} isn't available to you."}
          resolved -> check_target(resolved, to, chain)
        end
    end
  end

  defp check_target(resolved, to, chain) do
    cond do
      is_nil(Config.get_agent(resolved)) ->
        {:error, "Unknown agent: #{to}"}

      resolved in chain ->
        {:error, "Refusing to message #{resolved}: already in this chain (#{Enum.join(chain, " -> ")}); would loop."}

      length(chain) >= @max_hops ->
        {:error, "Agent message chain too deep (max #{@max_hops})."}

      true ->
        {:ok, resolved}
    end
  end

  # A model-typed target ("engenheiro") deserves the same case leeway a human gets from
  # `/agent engenheiro` finding "Engenheiro": match `can_message` (already in each agent's
  # exact-case canonical handle) case-insensitively, and use ITS value from here on, rather
  # than re-deriving a canonical form independently (which can disagree on how the root/
  # default scope is prefixed; see `Pepe.Config`'s `agent_handle/2` vs `Pepe.Project.qualify/2`).
  defp find_allowed(target, allowed) do
    Enum.find(allowed, &(String.downcase(&1) == String.downcase(target)))
  end

  @spec deliver(String.t(), String.t() | nil, String.t(), [String.t()], map()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp deliver(to, from_name, message, chain, ctx) do
    # Re-checked here (not just by the `is_nil(Config.get_agent(to))` cond clause
    # in run/2) so this function's own contract holds regardless of caller.
    case Config.get_agent(to) do
      nil ->
        {:error, "Unknown agent: #{to}"}

      agent ->
        prompt = "Message from agent #{from_name}:\n\n#{message}"

        opts = [
          agent_chain: chain ++ [to],
          authorize: ctx[:authorize],
          session_key: ctx[:session_key],
          # If this run has taken in a stranger's content, the message it is now handing to
          # another agent is that content (or shaped by it). The taint has to travel with it,
          # or a run reads a malicious document, is itself locked down, and then launders the
          # instruction through a peer that starts clean. See Pepe.Permissions.
          untrusted: Pepe.Permissions.tainted?(ctx)
        ]

        case Runtime.converse(agent, prompt, opts) do
          {:ok, reply, _msgs} ->
            {:ok,
             "#{to} replied:\n#{reply}\n\n(One-off consult only: you're still the one talking to the user. Don't say this connected them to #{to} or that #{to} is handling the conversation now.)"}

          {:error, reason} ->
            {:error, "#{to} could not reply: #{inspect(reason)}"}
        end
    end
  end
end
