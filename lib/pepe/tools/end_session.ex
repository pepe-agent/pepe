defmodule Pepe.Tools.EndSession do
  @moduledoc """
  Let an agent end its own conversation and clear the context - for a support
  channel, the agent calls this once the exchange is complete so the next message
  from that person starts fresh. The current reply is still delivered first; the
  agent's learned knowledge is untouched (only the live thread is cleared).
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "end_session"

  @impl true
  def spec do
    function(
      "end_session",
      "End the current conversation and clear its context. Call this when the " <>
        "exchange is finished (e.g. the customer is done and has been thanked) so the " <>
        "next message starts a fresh conversation. Your current reply is still sent first.",
      %{"type" => "object", "properties" => %{}, "required" => []}
    )
  end

  @impl true
  def run(_args, ctx) do
    case ctx[:session_key] do
      nil ->
        {:ok, "No session to end (this run isn't inside a persistent session)."}

      key ->
        Pepe.Agent.Session.end_session(key)
        {:ok, "Conversation ended - the context will be cleared for the next message."}
    end
  end
end
