defmodule Pepe.Permissions.PendingApproval do
  @moduledoc """
  One risky tool call that could not run because **nobody was there to authorize it** -
  parked, durably, for a human to approve or deny later (`mix pepe approvals`).

  This is the delayed-resolution counterpart to the live permission prompt: on an
  attended surface the gate blocks the call inline and resumes on the human's answer;
  on an unattended one (a cron, a webhook, the HTTP API) there is no prompt to render,
  and until this existed the call simply failed closed forever. The record holds enough
  to re-run the **exact** call once a human says yes (`tool` + the decoded `args`), plus
  where the answer should land (`session_key`/`origin`) and what saying "always" would
  actually grant (`grant`/`also_grant`, precomputed `Pepe.Permissions.Grant` strings, so
  the approval persists exactly the risks the gate saw - never a blank cheque inferred
  later).

  `tainted` records whether the run had taken in outside content when it asked - shown
  in `mix pepe approvals list`, because it is exactly the thing the human should weigh
  before approving (see `Pepe.Permissions`' "content from a stranger" moduledoc section).

  Not `Pepe.Approval` (the file-backed review queue for a background job's staged
  writes): that one stages a write *instead of running it* as an operator-opted-in
  review dial; this one is the gate's own ask, moved in time. Backed by `Pepe.Repo`
  (SQLite) like the other durable operational records (commitments, watches, traces).
  """

  use Ecto.Schema

  import Ecto.Changeset

  # App-generated string ids (short random hex), not Ecto's autoincrement integer -
  # a human has to type this id into a CLI command, so it stays short.
  @primary_key {:id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__]}
  schema "pending_approvals" do
    field :tool, :string
    field :args, :map, default: %{}
    field :session_key, :string
    field :agent, :string
    field :origin, :map, default: %{}
    field :grant, :string
    field :also_grant, :string
    field :tainted, :boolean, default: false
    # pending | approved | denied | expired
    field :status, :string, default: "pending"
    field :reason, :string
    field :created_at, :integer
    field :expires_at, :integer
    field :resolved_at, :integer
  end

  @type t :: %__MODULE__{}

  @fields ~w(id tool args session_key agent origin grant also_grant tainted status
             reason created_at expires_at resolved_at)a

  @doc "Build a changeset over the castable fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pending_approval, attrs) do
    pending_approval
    |> cast(attrs, @fields)
    |> validate_required([:tool])
    |> validate_inclusion(:status, ~w(pending approved denied expired))
  end
end
