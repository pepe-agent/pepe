defmodule Pepe.Tools.AskUser do
  @moduledoc """
  A genuine multiple-choice question to the user, rendered as real tappable buttons/menu
  native to whatever surface the conversation is on (Telegram inline buttons, the CLI's
  arrow-key menu, the dashboard's own picker) - not a text list the user has to reply to
  by typing a number. Blocks and returns the pick as this call's own result, so the agent
  keeps working in the same turn instead of ending it and hoping the next message answers
  the right question.

  An open-ended question doesn't need this: the agent can just ask, as its own reply, and
  end the turn - the user's next message answers it. This tool exists only for the case
  plain text handles badly - forcing a genuine pick among options, with nothing to
  misparse ("the second one, I meant B not A").

  Surfaces with nobody interactive to ask (the HTTP API, a webhook, a cron/watch/
  commitment-triggered run) don't wire `ctx.ask_user` at all, so the call fails outright
  instead of hanging forever waiting for a button nobody can press - the same shape
  `Pepe.Permissions` already uses for `ctx.authorize`.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "ask_user"

  @impl true
  def spec do
    function(
      "ask_user",
      "Ask the user to pick one of 2-6 short options, rendered as real tappable " <>
        "buttons/menu on whatever surface they're on. Blocks and returns their pick as " <>
        "this call's result - keep working in the same turn once you have it, do not end " <>
        "the turn first and wait for a plain reply. Only for a genuine multiple-choice " <>
        "decision; for an open-ended question, just ask in your own reply, no tool needed.",
      %{
        "type" => "object",
        "properties" => %{
          "question" => %{"type" => "string", "description" => "The question, shown above the options."},
          "choices" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "2 to 6 short option labels, shown verbatim as buttons/menu items."
          }
        },
        "required" => ["question", "choices"]
      }
    )
  end

  @impl true
  def run(%{"question" => q, "choices" => choices} = _args, ctx) when is_binary(q) and is_list(choices) do
    with {:ok, question, options} <- validate(q, choices),
         fun when is_function(fun, 2) <- ctx[:ask_user] || :unsupported do
      case fun.(question, options) do
        {:ok, pick} -> {:ok, pick}
        :timeout -> {:ok, "(the user didn't answer in time - ask again, or proceed with your best judgment)"}
      end
    else
      :unsupported ->
        {:error,
         "there is no interactive user to ask on this surface - state your assumption or " <>
           "what's missing instead of waiting for an answer"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(_args, _ctx), do: {:error, "ask_user needs `question` and `choices` (a list of 2-6 strings)"}

  defp validate(question, choices) do
    trimmed = Enum.map(choices, &(is_binary(&1) && String.trim(&1)))

    cond do
      String.trim(question) == "" ->
        {:error, "question can't be blank"}

      length(choices) < 2 or length(choices) > 6 ->
        {:error, "choices must have between 2 and 6 options"}

      Enum.any?(trimmed, &(&1 in [false, ""])) ->
        {:error, "each choice must be a non-empty string"}

      true ->
        {:ok, String.trim(question), trimmed}
    end
  end
end
