defmodule Pepe.Search.Result do
  @moduledoc "One web search result, however the occupying backend found it."

  @enforce_keys [:snippet]
  defstruct title: nil, url: nil, snippet: nil

  @type t :: %__MODULE__{title: String.t() | nil, url: String.t() | nil, snippet: String.t()}
end
