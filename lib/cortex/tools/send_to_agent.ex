defmodule Cortex.Tools.SendToAgent do
  @moduledoc """
  Send a message to another agent and return its reply — the agent-to-agent router.

  Routing is a **directed allowlist**: an agent may only message the agents listed
  in its `can_message`, so `A → B` does not imply `B → A`. The called agent answers
  in a fresh one-shot run (it sees the message labelled with the sender), and its
  reply comes back as this tool's result — answering is not itself "messaging", so
  no reverse route is needed.

  A **hop limit** and a **cycle check** keep chains from looping: a run carries the
  chain of agents so far (in `ctx.agent_chain`), and a call is refused if the target
  is already in the chain or the chain is too deep. The route allowlist is the
  authorization here, so the call isn't put through the human permission gate; the
  callee's own risky tools still are (the `authorize` callback is inherited).
  """

  @behaviour Cortex.Tools.Tool

  import Cortex.Tools.Tool, only: [function: 3]

  alias Cortex.Agent.Runtime
  alias Cortex.Company
  alias Cortex.Config

  @max_hops 5

  @impl true
  def name, do: "send_to_agent"

  @impl true
  def spec do
    function(
      "send_to_agent",
      "Send a message to another agent and get its reply. You may only message agents you're allowed to route to; their answer is returned to you. Use it to delegate work or ask a peer.",
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
    # A bare target resolves to a peer in the sender's own company.
    to = from_name && Company.qualify(to, from_name)

    cond do
      is_nil(from) ->
        {:error, "no calling agent in context"}

      # Hard tenant boundary: never route across companies, even if an allowlist or a
      # qualified handle asks for it. The route allowlist is scoped, this backs it up.
      not Company.same_scope?(to, from_name) ->
        {:error, "Refusing to message #{to}: it belongs to a different company."}

      to not in (from.can_message || []) ->
        {:error, "You're not allowed to message agent #{to}."}

      is_nil(Config.get_agent(to)) ->
        {:error, "Unknown agent: #{to}"}

      to in chain ->
        {:error,
         "Refusing to message #{to}: already in this chain (#{Enum.join(chain, " → ")}) — would loop."}

      length(chain) >= @max_hops ->
        {:error, "Agent message chain too deep (max #{@max_hops})."}

      true ->
        deliver(to, from_name, message, chain, ctx)
    end
  end

  def run(_args, _ctx), do: {:error, "send_to_agent needs `to` and `message`"}

  defp deliver(to, from_name, message, chain, ctx) do
    agent = Config.get_agent(to)
    prompt = "Message from agent #{from_name}:\n\n#{message}"

    opts = [
      agent_chain: chain ++ [to],
      authorize: ctx[:authorize],
      session_key: ctx[:session_key]
    ]

    case Runtime.converse(agent, prompt, opts) do
      {:ok, reply, _msgs} -> {:ok, "#{to} replied:\n#{reply}"}
      {:error, reason} -> {:error, "#{to} could not reply: #{inspect(reason)}"}
    end
  end
end
