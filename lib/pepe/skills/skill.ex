defmodule Pepe.Skills.Skill do
  @moduledoc """
  One discovered skill: where it lives, which tier it came from, and what its header says.

  `name` is the file or directory name (what `mix pepe skill install` places and what
  `Pepe.Agent.Workspace.resolve/2` reaches as `skills/<name>...`); the header's own `name`
  is kept in `fields.name` and is accepted as an alias when a skill is looked up.
  """

  defstruct [
    :name,
    :summary,
    :entry,
    :dir,
    :source,
    :category,
    :root,
    format: :loose,
    meta: %{},
    fields: %{},
    yaml: :none,
    quarantined?: false
  ]

  @type source :: :project | :user | :external | :builtin

  @type t :: %__MODULE__{
          name: String.t(),
          summary: String.t(),
          entry: String.t(),
          dir: String.t() | nil,
          source: source(),
          category: String.t() | nil,
          root: String.t(),
          format: :loose | :package,
          meta: map(),
          fields: map(),
          yaml: atom(),
          quarantined?: boolean()
        }

  @doc "The `category/name` path form of a skill (just `name` when it has no category)."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{category: nil, name: name}), do: name
  def path(%__MODULE__{category: category, name: name}), do: category <> "/" <> name
end
