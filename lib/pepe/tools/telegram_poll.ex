defmodule Pepe.Tools.TelegramPoll do
  @moduledoc """
  Post a native Telegram poll to the current conversation: a real tappable poll message,
  not a text list of options. Telegram-only - on any other channel this returns a clear
  error instead of pretending to send something.
  """
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  @impl true
  def name, do: "telegram_poll"

  @impl true
  def spec do
    function(
      "telegram_poll",
      "Post a native Telegram poll to the current conversation (a real tappable poll, not a " <>
        "text list). Only works in a Telegram conversation. Use for a genuine multiple-choice " <>
        "question to the group or user, not as a substitute for a normal reply.",
      %{
        "type" => "object",
        "properties" => %{
          "question" => %{"type" => "string", "description" => "The poll's question."},
          "options" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "2 to 10 answer options."
          },
          "anonymous" => %{"type" => "boolean", "description" => "Hide who voted for what. Default true."},
          "multiple" => %{"type" => "boolean", "description" => "Allow picking more than one option. Default false."},
          "quiz" => %{
            "type" => "boolean",
            "description" => "Make this a quiz poll with one correct answer (needs `correct_option`). Default false."
          },
          "correct_option" => %{
            "type" => "integer",
            "description" => "0-based index into `options` for the correct answer. Required when `quiz` is true."
          }
        },
        "required" => ["question", "options"]
      }
    )
  end

  @impl true
  def run(%{"question" => q, "options" => opts} = args, ctx) when is_binary(q) and is_list(opts) do
    with {:ok, target} <- telegram_target(ctx),
         {:ok, options} <- validate_options(opts),
         {:ok, poll_opts} <- build_opts(args) do
      case Pepe.Gateways.Telegram.deliver_poll(target, q, options, poll_opts) do
        :ok -> {:ok, "Poll posted."}
        {:error, :no_token} -> {:error, "This bot has no token configured."}
        {:error, reason} -> {:error, "Failed to post the poll: #{inspect(reason)}"}
      end
    end
  end

  def run(_args, _ctx), do: {:error, "telegram_poll needs `question` and `options`"}

  defp telegram_target(ctx) do
    case ctx[:session_key] do
      "telegram:" <> rest -> {:ok, rest}
      _ -> {:error, "telegram_poll only works in a Telegram conversation."}
    end
  end

  defp validate_options(opts) do
    strings = Enum.filter(opts, &(is_binary(&1) and String.trim(&1) != ""))

    if length(strings) in 2..10,
      do: {:ok, strings},
      else: {:error, "a poll needs 2 to 10 non-empty options"}
  end

  defp build_opts(%{"quiz" => true} = args) do
    case args["correct_option"] do
      n when is_integer(n) and n >= 0 -> {:ok, [type: "quiz", correct_option_id: n, anonymous: anonymous(args)]}
      _ -> {:error, "a quiz poll needs `correct_option` (the index of the right answer)"}
    end
  end

  defp build_opts(args), do: {:ok, [anonymous: anonymous(args), multiple: args["multiple"] == true]}

  defp anonymous(args), do: args["anonymous"] != false
end
