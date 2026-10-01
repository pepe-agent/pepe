defmodule Pepe.Decide.Jev do
  @moduledoc """
  The connection type for TypeSafe's decision model (`model.api == "typesafe-systemone"`):
  a model that does not write text, it answers a typed question with one of the options
  you describe, a probability for each, and a confidence between 0 and 1.

  It is a model connection like any other (a name, a base URL, a key kept as `${ENV_VAR}`,
  its own `fallbacks`), but it can only *decide*. Asking it to chat is refused here, and the
  places that let a person pick a model for conversation never list it. What uses it is
  `Pepe.Decide`, for the two places Pepe already asks a cheap model "which of these?": the
  complexity triage and the mid-turn message check.

  One request carries one `choice` question:

      POST <base_url>   Authorization: Bearer <key>
      {"state": "...", "model": "jev-latest",
       "questions": {"decision": {"type": "choice", "instructions": "...", "criteria": {"a": "...", "b": "..."}}}}

  and the answer is read from `answers.decision` (`choice`, `confidence`) with the token
  counts from `usage`.
  """

  @behaviour Pepe.LLM.Adapter

  alias Pepe.Config.Model

  # Short on purpose: a decision that takes seconds is worse than the model it replaces, and
  # `Pepe.Decide` has a normal model to fall back to when this one is slow.
  @receive_timeout 2_500
  @question "decision"

  @impl true
  def api, do: "typesafe-systemone"

  @impl true
  def chat(_model, _messages, _opts), do: {:error, "this connection only makes decisions, it cannot chat"}

  @impl true
  def stream_chat(_model, _messages, _on_delta, _opts), do: {:error, "this connection only makes decisions, it cannot chat"}

  @impl true
  def list_models(_model), do: {:ok, ["jev-latest"]}

  @doc """
  Ask one choice question. `question` carries `:state` (what is being judged),
  `:instructions` and `:criteria` (option name => what it means). Returns the option picked,
  its confidence and the usage in the shape `Pepe.Usage.record/3` reads, or `{:error, reason}`
  (an HTTP failure is `{:http_error, status, body}`, same as the chat adapters).
  """
  @spec decide(Model.t(), map()) :: {:ok, String.t(), float() | nil, map() | nil} | {:error, term()}
  def decide(%Model{} = model, question) do
    body = %{
      "state" => question.state,
      "model" => model.model || "jev-latest",
      "questions" => %{
        @question => %{"type" => "choice", "instructions" => question.instructions, "criteria" => question.criteria}
      }
    }

    case Req.post(model.base_url, json: body, headers: headers(model), receive_timeout: @receive_timeout, retry: false) do
      {:ok, %{status: 200, body: response}} -> read(response, question.criteria)
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp read(%{"answers" => %{@question => %{"choice" => choice} = answer}} = response, criteria) do
    if Map.has_key?(criteria, choice),
      do: {:ok, choice, number(answer["confidence"]), usage(response["usage"])},
      else: {:error, "unexpected option #{inspect(choice)} in the answer"}
  end

  defp read(_response, _criteria), do: {:error, "the answer had no decision in it"}

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp usage(%{"input_tokens" => input, "output_tokens" => output}) when is_integer(input) and is_integer(output),
    do: %{"prompt_tokens" => input, "completion_tokens" => output, "total_tokens" => input + output}

  defp usage(_usage), do: nil

  defp headers(%Model{} = model) do
    base = %{"content-type" => "application/json"}

    base =
      case Model.resolved_api_key(model) do
        key when is_binary(key) and key != "" -> Map.put(base, "authorization", "Bearer " <> key)
        _ -> base
      end

    Map.merge(base, Model.resolved_headers(model))
  end
end
