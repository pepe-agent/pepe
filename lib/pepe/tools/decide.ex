defmodule Pepe.Tools.Decide do
  @moduledoc """
  Ask a decision model to pick one of a few named options for a piece of text, and get back
  the choice with how sure it is: the agent's way of using a decision-only connection
  (`Pepe.Decide.Jev`) for a quick, well-scoped call it would otherwise spend a full chat turn
  on, or cannot judge its own certainty about.

  On offer only while a decision connection is reachable for the calling agent
  (`Pepe.Decide.connections_for/1`), so an install without one never shows the model a tool it
  cannot use. The connection's own fallbacks answer when it cannot, so the model gets a choice
  from a normal model instead of an error, just without a confidence to branch on. Nothing is
  sent anywhere the model has not already seen: the text is what the model itself passed in,
  after any redaction hook ran on the conversation.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Decide

  @max_options 20

  @impl true
  def name, do: "decide"

  @impl true
  def spec do
    function(
      "decide",
      "Get a quick, calibrated decision from a fast decision model: it picks ONE of the options you name for a piece of text and says how sure it is. Use it for a small, well-scoped choice you make again and again or must act on by certainty (is this message urgent, which team owns this ticket, is this a refund request), not for open-ended judgment or advice. Ask one specific thing per call, describe each option so it can be told apart from the others, and include a catch-all like \"other\" when the list might be incomplete. Pass only the text to judge. The answer carries a confidence: high means act on it, medium means confirm with the user or check, low means do not act, ask the user or decide yourself.",
      %{
        "type" => "object",
        "properties" => %{
          "question" => %{"type" => "string", "description" => "The one thing to decide, as a question."},
          "text" => %{"type" => "string", "description" => "The text to judge: a message, a ticket, a description."},
          "options" => %{
            "type" => "array",
            "description" => "The options to pick from, 2 to #{@max_options}.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string", "description" => "A short option name, returned verbatim as the choice."},
                "description" => %{"type" => "string", "description" => "What this option means, written to tell it apart from the others."}
              },
              "required" => ["name", "description"]
            }
          }
        },
        "required" => ["question", "text", "options"]
      }
    )
  end

  # Not offered when there is no decision connection to ask (see the moduledoc).
  @impl true
  def offered?(ctx), do: Decide.connections_for(ctx[:agent]) != []

  # Only reaches out to a model and changes nothing here.
  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"question" => question, "text" => text, "options" => options}, ctx)
      when is_binary(question) and is_binary(text) and is_list(options) do
    with {:ok, criteria} <- criteria(options),
         [_ | _] = chain <- Decide.connections_for(ctx[:agent]) do
      ask(chain, question, text, criteria, ctx[:agent].name)
    else
      [] -> {:error, "no decision connection is available to this agent"}
      {:error, _} = error -> error
    end
  end

  def run(_args, _ctx), do: {:error, "decide needs `question`, `text` and `options` (a list of {name, description})"}

  defp ask(chain, question, text, criteria, agent_name) do
    request = %{
      state: text,
      instructions: question,
      criteria: criteria,
      default: nil,
      # Not gated here: the confidence goes back to the model, which decides what to do with it.
      min_confidence: 0.0,
      chat_system: chat_prompt(question, criteria),
      chat_user: text
    }

    case Decide.choose(chain, request, agent_name) do
      %{choice: nil} -> {:error, "no connection could answer right now: decide this yourself or ask the user"}
      %{choice: choice, confidence: confidence, via: via} -> {:ok, report(choice, confidence, via)}
    end
  end

  # What the model sees back. The band spells out what to do, so it does not have to remember
  # the thresholds from the description.
  defp report(choice, nil, via),
    do:
      "decision: #{choice}\nconfidence: not available (answered by #{via}, a chat model, as a backup). Treat it as a reasonable guess, and check anything that matters."

  defp report(choice, confidence, via) do
    band =
      cond do
        confidence >= 0.9 -> "high: act on it"
        confidence >= 0.5 -> "medium: confirm with the user or check before acting"
        true -> "low: do not act on it, ask the user or decide yourself"
      end

    "decision: #{choice}\nconfidence: #{Float.round(confidence * 1.0, 2)} (#{band})\nanswered by: #{via}"
  end

  defp criteria(options) when length(options) in 2..@max_options do
    pairs = Enum.map(options, &option/1)

    cond do
      Enum.any?(pairs, &(&1 == :invalid)) ->
        {:error, "each option needs a non-empty `name` and `description`"}

      pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() != length(pairs) ->
        {:error, "option names must be different from each other"}

      true ->
        {:ok, Map.new(pairs)}
    end
  end

  defp criteria(_options), do: {:error, "`options` must list between 2 and #{@max_options} options"}

  defp option(%{"name" => name, "description" => description}) when is_binary(name) and is_binary(description) do
    if String.trim(name) == "" or String.trim(description) == "", do: :invalid, else: {String.trim(name), String.trim(description)}
  end

  defp option(_other), do: :invalid

  # The chat-model backup: the same question as a one-word answer.
  defp chat_prompt(question, criteria) do
    list = Enum.map_join(criteria, "\n", fn {name, description} -> "- #{name}: #{description}" end)

    "#{question}\n\nReply with exactly one of these option names and nothing else:\n#{list}"
  end
end
