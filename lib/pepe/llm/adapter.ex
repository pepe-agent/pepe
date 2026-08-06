defmodule Pepe.LLM.Adapter do
  @moduledoc """
  Translates the OpenAI Chat Completions shape `Pepe.LLM` speaks everywhere else into a
  different provider protocol - the same role `Pepe.LLM.Responses` (OpenAI's own Responses
  API) and `Pepe.LLM.Messages` (Anthropic's Messages API) already play as core code.

  This is additive, not a slot (see `Pepe.Slots`): `model.api` already selects a protocol
  per model connection, and several connections using different protocols must all work at
  once - there is no single "the" adapter to swap. A plugin adds a new `api` value to the
  dispatch table; it can never replace `"openai-responses"`/`"anthropic-messages"` (builtins
  win a name clash - same rule `Pepe.Tools` uses, the opposite of `Pepe.Webhooks`, which lets
  a plugin provider replace a built-in one of the same name on purpose), and any `model.api`
  matching neither a builtin nor an installed plugin still runs as plain
  openai-completions - the fall-through every existing config already relies on.
  """

  alias Pepe.Config.Model
  alias Pepe.LLM

  @callback api() :: String.t()
  @callback chat(Model.t(), [map()], keyword()) :: {:ok, LLM.result()} | {:error, term()}
  @callback stream_chat(Model.t(), [map()], (String.t() -> any()), keyword()) ::
              {:ok, LLM.result()} | {:error, term()}
  @callback list_models(Model.t()) :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks list_models: 1
end
