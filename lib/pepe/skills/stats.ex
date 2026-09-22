defmodule Pepe.Skills.Stats do
  @moduledoc """
  The counters and flags behind skill ownership and the skill lifecycle: which skills an
  agent wrote (`managed`), which a person pinned, how often each is read, used, changed or
  found wrong, and where it sits between `active`, `stale` and `archived`.

  Everything here is **best-effort telemetry**. A skill must never fail to load, or a turn
  fail to finish, because `Pepe.Repo` hiccuped, so every write degrades to a logged warning
  (the same posture `Pepe.Permissions.Grants` takes for its ledger). The one thing that is
  *not* soft is what the rows are used for: `managed` and `pinned` decide what the
  background review and the curator are allowed to touch at all (see
  `Pepe.Skills.Ownership`), and an unreadable row reads as "not managed, not pinned", i.e.
  protected - the safe direction.

  The counters:

    * **view** - the skill was opened with the `skill` tool.
    * **use** - a turn that opened it ended without a failure after it.
    * **fail** - a tool call failed after the skill was opened, the one piece of evidence
      that its own instructions led somewhere that does not work (see
      `Pepe.Agent.SkillLearning.refine_target/1`).
    * **patch** - it was created or changed through `skill_manage`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Pepe.Repo
  alias Pepe.Skills.Stat

  @doc "The stats row for `name`, or `nil` (never recorded, or storage unreachable)."
  @spec get(String.t()) :: Stat.t() | nil
  def get(name) when is_binary(name), do: safe(fn -> Repo.get(Stat, name) end, nil)

  @doc "Every stats row, keyed by skill name."
  @spec all() :: %{optional(String.t()) => Stat.t()}
  def all, do: safe(fn -> Stat |> Repo.all() |> Map.new(&{&1.name, &1}) end, %{})

  @doc """
  Record that `name` now exists and who wrote it. `managed?` is whether the background
  review and curator may maintain it on their own - true for a skill an agent created,
  false for one a person wrote or installed. Keeps an existing row's counters.
  """
  @spec record_created(String.t(), String.t(), boolean()) :: :ok
  def record_created(name, created_by, managed?) do
    now = now()

    safe(
      fn ->
        Repo.insert!(
          %Stat{name: name, created_at: now, created_by: created_by, managed: managed?, last_patched_at: now, state_changed_at: now},
          on_conflict: [set: [managed: managed?, created_by: created_by, last_patched_at: now, state: "active", state_changed_at: now]],
          conflict_target: :name
        )

        :ok
      end,
      :ok
    )
  end

  @doc "A person handed an existing skill to the curator (`pepe skill adopt`): it becomes managed."
  @spec adopt(String.t(), String.t()) :: :ok
  def adopt(name, actor) do
    ensure_row(name)
    update(name, set: [managed: true, created_by: actor])
  end

  @doc "Take a skill back out of curator management (`pepe skill release`)."
  @spec release(String.t()) :: :ok
  def release(name) do
    ensure_row(name)
    update(name, set: [managed: false])
  end

  @doc "Pin (`true`) or unpin a skill. A pinned skill is never changed by anything but a person."
  @spec pin(String.t(), boolean()) :: :ok
  def pin(name, pinned?) do
    ensure_row(name)
    update(name, set: [pinned: pinned?])
  end

  @doc "The skill was opened with the `skill` tool."
  @spec bump_view(String.t()) :: :ok
  def bump_view(name), do: bump(name, :view_count, :last_viewed_at)

  @doc "A turn that opened the skill ended without anything failing after it."
  @spec bump_use(String.t()) :: :ok
  def bump_use(name), do: bump(name, :use_count, :last_used_at)

  @doc "Something failed after the skill was opened - its instructions may be wrong."
  @spec bump_fail(String.t()) :: :ok
  def bump_fail(name) do
    ensure_row(name)
    update(name, inc: [fail_count: 1])
  end

  @doc "The skill was created or changed."
  @spec bump_patch(String.t()) :: :ok
  def bump_patch(name), do: bump(name, :patch_count, :last_patched_at)

  @doc "Move a skill to `state` (`active`, `stale` or `archived`)."
  @spec set_state(String.t(), String.t()) :: :ok
  def set_state(name, state) when state in ~w(active stale archived) do
    ensure_row(name)
    update(name, set: [state: state, state_changed_at: now()])
  end

  @doc "Drop the row for a skill that no longer exists (`pepe skill purge`)."
  @spec forget(String.t()) :: :ok
  def forget(name), do: safe(fn -> Repo.delete_all(from(s in Stat, where: s.name == ^name)) && :ok end, :ok)

  @doc false
  # Every write in this module funnels through here so a storage failure is a warning, never a
  # crash that reaches the skill tool or the end of a turn.
  @spec safe((-> result), result) :: result when result: term()
  def safe(fun, default) do
    fun.()
  rescue
    e ->
      Logger.warning("[skills] stats unavailable: #{Exception.message(e)}")
      default
  catch
    :exit, reason ->
      Logger.warning("[skills] stats unavailable: #{inspect(reason)}")
      default
  end

  defp bump(name, count_field, at_field) do
    ensure_row(name)
    update(name, inc: [{count_field, 1}], set: [{at_field, now()}])
  end

  # A row appears the first time anything records something about a skill, with its inactivity
  # clock starting now, not at the epoch - a skill that existed long before this table did must
  # not look decades stale on first sight.
  defp ensure_row(name) do
    now = now()
    safe(fn -> Repo.insert!(%Stat{name: name, created_at: now}, on_conflict: :nothing, conflict_target: :name) && :ok end, :ok)
  end

  defp update(name, ops) do
    safe(fn -> Repo.update_all(from(s in Stat, where: s.name == ^name), ops) && :ok end, :ok)
  end

  defp now, do: System.system_time(:second)
end
