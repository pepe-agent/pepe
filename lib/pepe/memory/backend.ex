defmodule Pepe.Memory.Backend do
  @moduledoc """
  The `memory` slot's contract (see `Pepe.Slots`). `opts` may carry `:limit` and a `:mode`
  hint (`:keyword | :vector | :hybrid`) - the builtin ignores `:mode`; a backend that does
  understand it (a vector store) satisfies the exact same contract, so a richer occupant is
  a config change (`mix pepe slot set memory NAME`), never a new call shape.

  `index/1` is optional: the builtin has nothing to index (it reads memory files straight
  off disk on every call), while a backend that maintains its own store (embeddings, a
  remote index) needs one. `Pepe.Memory.reindex/1` no-ops when the current occupant doesn't
  export it.
  """

  @callback name() :: String.t()
  @callback slot() :: String.t()
  @callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
              {:ok, [Pepe.Memory.Hit.t()]} | {:error, term()}
  @callback capabilities() :: %{keyword: boolean(), vector: boolean()}
  @callback index(agent_name :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks capabilities: 0, index: 1
end
