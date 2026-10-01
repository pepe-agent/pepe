defmodule Pepe.Tools.HandBack do
  @moduledoc """
  How a specialist agent hands a conversation back to the channel's own agent (the
  router, the one `/new` returns to) when the user has clearly moved on to something
  outside the specialist's scope. Offered by the runtime on its own, never listed in an
  agent's `tools`: it exists only while the agent has `topic_reroute` on (see
  `Pepe.Config.Agent`), is only offered when this conversation is currently *not* with
  the channel's own agent, and is hidden on a connection that locks agent switching.

  It always asks first. A side question ("and what does that cost?") must not pull the
  user out of the agent they're talking to, so the specialist puts a yes/no to the
  person, in their language, and only a yes hands the conversation back. On a surface
  with buttons (`ctx.ask_user`) the question is a real tappable choice and a yes also
  re-sends the user's message to the router, which routes it, so nobody has to repeat
  themselves. On a surface with no way to ask that way, the specialist asks in its own
  reply and calls this again with `confirmed: true` once the user said yes. The message
  that triggered the question was remembered when it was asked, so that yes re-sends it (not
  the "yes" itself) and nobody repeats anything there either.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Agent.Session

  @impl true
  def name, do: "hand_back"

  @impl true
  def spec do
    function(
      "hand_back",
      "The user's latest message is clearly about something outside what you cover, so the conversation probably belongs with another agent. Call this to ask the user whether to pass the conversation back to the agent that routes requests. It asks them with yes/no buttons and, on yes, hands the conversation back and re-sends their message so they do not have to repeat it. Write `question`, `yes` and `no` in the user's own language. If the user says no, keep answering them yourself and do not offer again until the subject changes again. Do not call this for a side question you can simply answer, or when unsure the subject really changed. If this surface has no buttons, the call tells you so: ask in your own reply, end the turn, and when they answer yes call this again with `confirmed` true.",
      %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" =>
              "The yes/no question to show, e.g. that the subject seems to have changed and whether to move the conversation to the right agent."
          },
          "yes" => %{"type" => "string", "description" => "Short label for the yes button."},
          "no" => %{"type" => "string", "description" => "Short label for the no button."},
          "confirmed" => %{
            "type" => "boolean",
            "description" => "True only when the user has already said yes in plain text, so nothing needs asking."
          }
        },
        "required" => []
      }
    )
  end

  # On offer only while the agent has `topic_reroute` on, this conversation is with someone
  # other than the channel's own agent (`ctx.handback`, set by the session), and the channel
  # does not lock agent switching. The registry hides it and refuses a call otherwise.
  @impl true
  def offered?(ctx) do
    match?(%{topic_reroute: true}, ctx[:agent]) and ctx[:handback] == true and ctx[:agent_switch_locked] != true
  end

  @impl true
  def run(args, ctx) do
    with :ok <- authorize(ctx) do
      if args["confirmed"] == true do
        handed_back(ctx, :remembered)
      else
        ask(args, ctx)
      end
    end
  end

  defp ask(args, ctx) do
    question = text(args["question"], "The subject seems to have changed. Move the conversation to the right agent?")
    yes = text(args["yes"], "Yes")
    no = text(args["no"], "No")

    case ctx[:ask_user] do
      fun when is_function(fun, 2) ->
        case fun.(question, [yes, no]) do
          {:ok, ^yes} -> handed_back(ctx, true)
          {:ok, _no} -> {:ok, stayed()}
          :timeout -> {:ok, stayed()}
        end

      _ ->
        Session.remember_handback(ctx[:session_key])

        {:ok,
         "There are no buttons on this surface. Ask the user the question in your own reply, in their language, and end the turn. If they answer yes, call hand_back again with confirmed true."}
    end
  end

  # `forward?` re-sends the user's message to the router (see `Session.hand_back/2`);
  # `:remembered` re-sends the one stored when the plain-text question was asked, if any. The
  # tool result is what the model sees next, and it must not write a goodbye the user would
  # then be shown on top of the router's own answer.
  defp handed_back(ctx, forward?) do
    Session.hand_back(ctx[:session_key], forward?)
    {:ok, "Handed back. Their message is going to the routing agent now: write nothing more."}
  end

  defp stayed do
    "The user chose to stay with you. Answer their message yourself, and do not offer to hand the conversation back again unless the subject changes again."
  end

  defp text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp text(_value, default), do: default

  defp authorize(ctx) do
    if is_nil(ctx[:session_key]),
      do: {:error, "no session to hand back: this only works inside a real conversation"},
      else: :ok
  end
end
