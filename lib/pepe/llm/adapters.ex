defmodule Pepe.LLM.Adapters do
  @moduledoc """
  The dispatch table `Pepe.LLM` looks a model's `api` string up in - see `Pepe.LLM.Adapter`
  for what an entry is and why this is additive rather than a slot.
  """

  @builtin %{"openai-responses" => Pepe.LLM.Responses, "anthropic-messages" => Pepe.LLM.Messages}

  @doc "The adapter module for `api`, or nil (meaning: run as plain openai-completions)."
  @spec get(String.t() | nil) :: module() | nil
  def get(api), do: Map.get(registry(), api)

  @doc "Every known api => adapter module, builtins winning any name clash with a plugin."
  @spec registry() :: %{String.t() => module()}
  def registry, do: Map.merge(plugin_adapters(), @builtin)

  # api/0 runs in the caller's process, before Pepe.LLM.safe_adapter/3's isolation exists
  # for a plugin to run inside - and this registry is rebuilt on every chat/stream_chat/
  # list_models call, for every model, including ones that never touch a plugin adapter.
  # A module whose api/0 itself raises is simply not registered (logged, skipped), not a
  # reason every model call in the installation fails.
  defp plugin_adapters do
    [{:api, 0}, {:chat, 3}, {:stream_chat, 4}]
    |> Pepe.Plugins.implementing()
    |> Enum.flat_map(fn mod ->
      case Pepe.Plugins.safe_call(mod, :api, []) do
        {:ok, api} when is_binary(api) -> [{api, mod}]
        _ -> []
      end
    end)
    |> Map.new()
  end
end
