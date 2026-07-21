defmodule Pepe.Usage.Entry do
  @moduledoc """
  One row of `Pepe.Usage.Log` - see that module's moduledoc for what it records. The
  schema itself is internal: every public `Pepe.Usage.Log` function takes/returns a bare
  string-keyed map (the same shape the old JSONL lines had), not this struct.
  """

  use Ecto.Schema

  schema "usage_entries" do
    field :project, :string
    field :at, :integer
    field :agent, :string
    field :model, :string
    field :in, :integer
    field :out, :integer
    field :sub, :boolean, default: false
    field :cached, :integer
  end
end
