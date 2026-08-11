defmodule Pepe.Usage.PrepaidBalance do
  @moduledoc """
  One row of the `prepaid_balances` table - see `Pepe.Usage.Prepaid`'s moduledoc for
  what it means. Internal: every public function is on `Pepe.Usage.Prepaid`, not here.
  """

  use Ecto.Schema

  @primary_key {:project, :string, autogenerate: false}
  schema "prepaid_balances" do
    field :balance, :float
    field :settled_through_id, :integer
  end
end
