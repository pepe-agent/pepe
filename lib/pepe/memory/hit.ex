defmodule Pepe.Memory.Hit do
  @moduledoc "One memory search result, however the occupying backend found it."

  @enforce_keys [:file, :entry]
  defstruct file: nil, entry: nil, score: nil, source: nil

  @type t :: %__MODULE__{
          file: String.t(),
          entry: String.t(),
          score: number() | nil,
          source: String.t() | nil
        }
end
