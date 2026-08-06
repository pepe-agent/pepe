defmodule Pepe.Search.Backend do
  @moduledoc "The `web_search` slot's contract (see `Pepe.Slots`)."

  @callback name() :: String.t()
  @callback slot() :: String.t()
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [Pepe.Search.Result.t()]} | {:error, term()}
end
