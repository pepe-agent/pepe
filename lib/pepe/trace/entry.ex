defmodule Pepe.Trace.Entry do
  @moduledoc """
  One row of `Pepe.Trace` - see that module's moduledoc for what it records. The schema
  itself is internal: every public `Pepe.Trace` function takes/returns a bare
  string-keyed map (the same shape the old per-run JSON file had), not this struct -
  the atom/string boundary conversion happens entirely inside `Pepe.Trace`.
  """

  use Ecto.Schema

  # App-generated string ids (a microsecond timestamp), not Ecto's default autoincrement.
  @primary_key {:id, :string, autogenerate: false}
  schema "traces" do
    field :scope, :string
    field :at, :integer
    field :agent, :string
    field :session, :string
    field :source, :string
    field :prompt, :string
    field :ms, :integer
    field :outcome, :map, default: %{}
    field :events, {:array, :map}, default: []
  end
end
