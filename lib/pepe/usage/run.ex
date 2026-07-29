defmodule Pepe.Usage.Run do
  @moduledoc """
  One row of `Pepe.Usage.Runs` - see that module's moduledoc. Internal, like every other
  schema under `Pepe.Usage`: the public functions take and return string-keyed maps.
  """

  use Ecto.Schema

  # The run's own id, shared with the trace it came from - not an autoincrement.
  @primary_key {:id, :string, autogenerate: false}
  schema "usage_runs" do
    field :project, :string
    field :at, :integer
    field :agent, :string
    field :session, :string
    field :source, :string
    field :ms, :integer
    field :outcome, :string
    field :tools, {:array, :string}, default: []
  end
end
