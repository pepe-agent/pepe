defmodule Pepe.Flow.Flow do
  @moduledoc """
  One row of `Pepe.Flow` - see that module's moduledoc for what it records. The schema
  itself is internal: every public `Pepe.Flow` function takes/returns a bare string-keyed
  map, not this struct - the atom/string boundary conversion happens entirely inside
  `Pepe.Flow`.
  """

  use Ecto.Schema

  # App-generated string ids, not Ecto's default autoincrement - matches every other
  # operational subsystem's id shape (Pepe.Trace.Trace, Pepe.Config.Watch, ...).
  @primary_key {:id, :string, autogenerate: false}
  schema "flows" do
    field :name, :string
    field :agent, :string
    field :steps, {:array, :map}, default: []
    field :source_trace_ids, {:array, :string}, default: []
    field :created_at, :integer
    field :last_run, :integer
    field :last_result, :string
  end
end
