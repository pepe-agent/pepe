defmodule Pepe.Config.Watch do
  @moduledoc """
  A **watch** - a one-shot, durable "check X and notify me when it happens".

  Created on demand (the agent calls `notify_when` when you ask), it lives on disk so
  it survives a restart and the originating session closing, and it **stops once it
  fires**. Two cost tiers, chosen at creation:

    * `trigger` - how the condition is re-checked every interval:
      * `%{"type" => "probe", "command" => "curl -sf https://x", "success" => "exit_zero"}`
        - a cheap shell probe, **no LLM per check** (success = exit 0, or
        `%{"contains" => "..."}` against stdout).
      * `%{"type" => "agent", "prompt" => "has the deploy finished?"}` - re-ask the
        agent when the condition needs judgement (one LLM call per check).
    * `on_fire` - what to send when it fires:
      * `%{"type" => "template", "text" => "✅ site is back"}` - a fixed message, no LLM.
      * `%{"type" => "agent", "prompt" => "summarise the deploy result"}` - the agent
        composes the message (one LLM call, once).

  `origin` records where to deliver - `%{"channel" => "telegram", "chat_id" => ...}` -
  captured when the watch is created, so the reply lands on the channel you asked from
  even after a restart.

  Backed by `Pepe.Repo` (SQLite), not `config.json` - see that module's moduledoc for why.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # App-generated string ids, not Ecto's default autoincrement integer.
  @primary_key {:id, :string, autogenerate: false}
  # An Ecto schema struct carries a hidden __meta__ that isn't itself Jason-encodable.
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "watches" do
    field :description, :string
    field :agent, :string
    field :trigger, :map, default: %{}
    field :on_fire, :map, default: %{}
    field :origin, :map, default: %{}
    field :interval_s, :integer, default: 120
    field :max_checks, :integer, default: 720
    field :checks, :integer, default: 0
    # pending | paused | done | expired | cancelled
    field :state, :string, default: "pending"
    field :created, :integer
    field :last_check, :integer
    field :next_check, :integer
    field :last_error, :string
    # Notification text held here when the origin channel was unreachable.
    field :pending_delivery, :string
  end

  @type t :: %__MODULE__{}

  @fields ~w(id description agent trigger on_fire origin interval_s max_checks checks
             state created last_check next_check last_error pending_delivery)a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(watch, attrs), do: cast(watch, attrs, @fields)

  @doc "Parse a raw config.json map (the pre-migration on-disk shape) into a changeset."
  @spec from_map(map()) :: Ecto.Changeset.t()
  def from_map(map) when is_map(map) do
    changeset(%__MODULE__{}, %{
      id: map["id"],
      description: map["description"],
      agent: map["agent"],
      trigger: map["trigger"] || %{},
      on_fire: map["on_fire"] || %{},
      origin: map["origin"] || %{},
      interval_s: map["interval_s"] || 120,
      max_checks: map["max_checks"] || 720,
      checks: map["checks"] || 0,
      state: map["state"] || "pending",
      created: map["created"],
      last_check: map["last_check"],
      next_check: map["next_check"],
      last_error: map["last_error"],
      pending_delivery: map["pending_delivery"]
    })
  end
end
