defmodule Pepe.Realtime do
  @moduledoc """
  Discovery for installed `Pepe.Realtime.Provider` plugins - additive, like
  `Pepe.Webhooks.providers/0`, not a `Pepe.Slots` occupant: a client picks a provider by
  name per connection (`PepeWeb.RealtimeChannel`'s join payload), and more than one can
  be installed at once (a cheap local pipeline and a hosted realtime model, say -
  different connections choose differently).
  """

  @funs [{:name, 0}, {:start, 3}, {:push_audio, 2}, {:stop, 1}]

  @doc "Every installed realtime provider's module, by name."
  @spec providers() :: %{String.t() => module()}
  def providers do
    @funs
    |> Pepe.Plugins.implementing()
    |> Enum.reduce(%{}, &index/2)
  end

  defp index(mod, acc) do
    case Pepe.Plugins.safe_call(mod, :name, []) do
      {:ok, name} when is_binary(name) -> Map.put(acc, name, mod)
      _ -> acc
    end
  end

  @doc "The provider module named `name`, or `nil` if none installed claims that name."
  @spec get(String.t()) :: module() | nil
  def get(name) when is_binary(name), do: providers()[name]
  def get(_name), do: nil
end
