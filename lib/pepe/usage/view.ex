defmodule Pepe.Usage.View do
  @moduledoc """
  Project a usage figure down to the money a **price view** is allowed to see.

  Three numbers exist for every metered call (see `Pepe.Usage`'s moduledoc): `list` (the
  tokens at the model's price), `billable` (list × the project's markup - what the client
  pays) and `cost` (what we actually paid). Who may see which is a property of the API token
  doing the reading, never of the request:

    * `"billable"` - what the client pays, and nothing else. The default.
    * `"list"` - the same tokens without the markup applied.
    * `"all"` - both, plus `cost` and the margin between them. The operator's view.

  `"billable"` and `"list"` are deliberately exclusive rather than cumulative. Showing both
  hands over their ratio, which is the markup, which is the margin - the thing `"all"`
  exists to gate. A client that is shown list prices is being shown list prices *instead*.
  """

  alias Pepe.ApiToken

  # Money is fractions of a cent per call - two decimals would round almost every single
  # entry to zero, so amounts are carried at the precision they are summed at.
  @decimals 6

  @doc """
  The money `view` may see, from a map carrying `:list`, `:cost` and `:billable` (the shape
  `Pepe.Usage`'s buckets and totals use). Returns a JSON-ready string-keyed map.
  """
  @spec money(map(), String.t()) :: map()
  def money(amounts, view) do
    case ApiToken.price_view(view) do
      "all" -> %{"list" => round6(amounts.list), "cost" => round6(amounts.cost), "billable" => round6(amounts.billable)}
      "list" -> %{"list" => round6(amounts.list)}
      _billable -> %{"billable" => round6(amounts.billable)}
    end
  end

  @doc "The same, from a priced ledger entry (string-keyed, as `Pepe.Usage.price_entries/2` returns)."
  @spec entry_money(map(), String.t()) :: map()
  def entry_money(entry, view) do
    money(%{list: entry["list"], cost: entry["cost"], billable: entry["billable"]}, view)
  end

  @doc """
  Token counts and call count, in the field names the API speaks. Shared by every shape the
  usage endpoints return, so a bucket, a run and a total all read the same way.
  """
  @spec counts(map()) :: map()
  def counts(amounts) do
    %{
      "calls" => amounts.count,
      "input_tokens" => amounts.in,
      "output_tokens" => amounts.out,
      "total_tokens" => amounts.total
    }
  end

  @doc "Counts and money together - the usual pairing."
  @spec amounts(map(), String.t()) :: map()
  def amounts(amounts, view), do: Map.merge(counts(amounts), money(amounts, view))

  @doc """
  Whether `view` may see the operator-only figures (margin, the month's subscription fees,
  a project's markup). Only `"all"` may: each of them either is the margin or reconstructs
  it.
  """
  @spec operator?(String.t()) :: boolean()
  def operator?(view), do: ApiToken.price_view(view) == "all"

  @doc "Round a money amount to the precision the API reports it at."
  @spec round6(number() | nil) :: float()
  def round6(nil), do: 0.0
  def round6(amount), do: Float.round(amount / 1, @decimals)
end
