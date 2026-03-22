defmodule Pepe.Cron.Generate do
  @moduledoc """
  Turn a plain-language schedule ("every weekday at 9am", "toda segunda às 9h") into a
  standard 5-field cron expression, using a configured model. The result is validated
  with `Pepe.Cron.parse/1`, so an invalid expression is never returned. Writing cron by
  hand is error-prone; this lets a user describe the schedule instead.
  """

  alias Pepe.Config
  alias Pepe.LLM.Message

  @doc """
  Generate a cron expression from `description`. Returns `{:ok, "0 9 * * 1"}` or
  `{:error, reason}`.
  """
  @spec from_text(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def from_text(description, model_name) do
    with model when not is_nil(model) <- Config.get_model(model_name),
         {:ok, %{content: content}} when is_binary(content) <-
           Pepe.LLM.chat(model, prompt(description), []),
         expr when expr != "" <- extract(content),
         {:ok, _} <- Pepe.Cron.parse(expr) do
      {:ok, expr}
    else
      nil -> {:error, :unknown_model}
      _ -> {:error, :generation_failed}
    end
  end

  defp prompt(description) do
    system = """
    Convert the user's schedule into a standard 5-field cron expression:
    "minute hour day-of-month month day-of-week". Reply with ONLY the expression,
    nothing else, no code fence.

    Examples:
    "every day at 8am" -> 0 8 * * *
    "every weekday at 9:30" -> 30 9 * * 1-5
    "every 15 minutes" -> */15 * * * *
    "first of the month at midnight" -> 0 0 1 * *
    """

    [Message.system(system), Message.user(description)]
  end

  # Take the first non-empty line and strip any stray fences/backticks.
  defp extract(content) do
    content
    |> String.replace("`", "")
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end
end
