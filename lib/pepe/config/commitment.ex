defmodule Pepe.Config.Commitment do
  @moduledoc """
  A **commitment** - something said during a conversation that implies a follow-up later:
  the user asking to be reminded ("me lembra de mandar o relatório sexta"), or the agent
  itself promising to check on something ("let me verify that and I'll tell you
  tomorrow"). Extracted automatically after a turn (see `Pepe.Agent.CommitmentExtract`),
  not created by hand.

  `origin_type` decides how it's delivered when due: `"user_reminder"` sends a canned
  message (the same thing `Pepe.Watch` already does); `"agent_promise"` re-runs the
  original agent session so it actually does the thing before replying, instead of just
  parroting the promise back.

  `source_excerpt` is the verbatim sentence the extraction says it came from - kept so a
  low-confidence commitment can be shown to a human with "here's why", and so the
  extraction can be mechanically checked against the real transcript before it's ever
  trusted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # App-generated string ids ("c_" <> hex), not Ecto's default autoincrement integer.
  @primary_key {:id, :string, autogenerate: false}
  # An Ecto schema struct carries a hidden __meta__ that isn't itself Jason-encodable -
  # the everyday footgun when deriving straight off a bare `@derive Jason.Encoder`.
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "commitments" do
    field :text, :string
    field :source_excerpt, :string
    field :due_when, :string
    field :due_at, :integer
    # "user_reminder" | "agent_promise"
    field :origin_type, :string, default: "user_reminder"
    field :agent, :string
    field :origin, :map, default: %{}
    field :confidence, :float
    # awaiting_confirmation | scheduled | firing | delivered | cancelled | expired
    field :state, :string, default: "awaiting_confirmation"
    field :created_at, :integer
    field :delivered_at, :integer
    field :last_error, :string
    # Fired but delivery failed (origin unreachable, session crashed) - held here
    # for the scheduler's next-tick retry, same shape as a watch's pending delivery.
    field :pending_delivery, :string
    # Set the moment state becomes "firing" (see Pepe.Commitments.Scheduler) - an
    # agent_promise's own fulfillment (re-running a real session) can take real time
    # and can crash mid-way, and this is the only record that it was ever attempted.
    field :firing_at, :integer
    # Derived from `text` (lowercased, punctuation-stripped), never caller-supplied -
    # what the near-duplicate unique index actually compares against. Recomputed on
    # every changeset, not just on create: a stale value here would silently escape
    # the index (a NULL never collides with another NULL), so a plain replace through
    # `put_commitment/1` must keep it current too.
    field :normalized_text, :string
  end

  @type t :: %__MODULE__{}

  @fields ~w(id text source_excerpt due_when due_at origin_type agent origin
             confidence state created_at delivered_at last_error pending_delivery firing_at)a

  @doc """
  Build a changeset, always recomputing `normalized_text` from `text` - the DB-level
  replacement for the old in-process duplicate check (see `Pepe.Config.create_commitment/1`
  and the partial unique index in its migration).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(commitment, attrs) do
    commitment
    |> cast(attrs, @fields)
    |> put_change(:normalized_text, normalize_text(get_field_after_cast(commitment, attrs)))
    # No custom :name - see the migration's comment on the same index for why: SQLite's
    # violation error only names columns, so ecto_sqlite3 re-derives Ecto's conventional
    # name from them, and a custom name here would silently stop matching it.
    |> unique_constraint([:agent, :normalized_text])
  end

  # The text a fresh changeset should normalize is whichever one attrs actually supplies
  # (a plain map may use either string or atom keys, matching from_map/1 and struct updates).
  defp get_field_after_cast(commitment, attrs),
    do: attrs[:text] || attrs["text"] || commitment.text

  @doc "Lowercased, punctuation-stripped, whitespace-trimmed - what the unique index compares."
  @spec normalize_text(String.t() | nil) :: String.t() | nil
  def normalize_text(nil), do: nil

  def normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @doc "Parse a raw config.json map (the pre-migration on-disk shape) into a changeset."
  @spec from_map(map()) :: Ecto.Changeset.t()
  def from_map(map) when is_map(map) do
    changeset(%__MODULE__{}, %{
      id: map["id"],
      text: map["text"],
      source_excerpt: map["source_excerpt"],
      due_when: map["due_when"],
      due_at: map["due_at"],
      origin_type: map["origin_type"] || "user_reminder",
      agent: map["agent"],
      origin: map["origin"] || %{},
      confidence: map["confidence"],
      state: map["state"] || "awaiting_confirmation",
      created_at: map["created_at"],
      delivered_at: map["delivered_at"],
      last_error: map["last_error"],
      pending_delivery: map["pending_delivery"],
      firing_at: map["firing_at"]
    })
  end
end
