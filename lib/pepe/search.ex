defmodule Pepe.Search do
  @moduledoc """
  The facade every caller searches the web through - routes to whichever backend currently
  occupies the `web_search` slot (see `Pepe.Slots`), degrading to DuckDuckGo on a
  misbehaving occupant (see `Pepe.Slots.Guard`). `Pepe.Tools.WebSearch` is a thin wrapper
  over this, mirroring `Pepe.Memory`/`Pepe.Tools.MemorySearch` - nothing else needs to know
  a slot exists.
  """

  alias Pepe.Search.Result

  @doc """
  Search the web for `query`. `agent` is optional - pass it when known so a per-agent slot
  override (`Pepe.Slots.occupant/2`) is actually honored, instead of falling back to the
  installation-wide occupant.
  """
  @spec search(String.t(), keyword(), Pepe.Config.Agent.t() | nil) :: {:ok, [Result.t()]} | {:error, term()}
  def search(query, opts \\ [], agent \\ nil) do
    Pepe.Slots.Guard.call("web_search", :search, [query, opts], agent)
  end
end
