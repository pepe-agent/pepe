defmodule Pepe.Skills.Ledger do
  @moduledoc """
  The audit trail for skills: one row per change, with who made it.

  An *actor* is a plain string naming the source of a change: `"agent:<name>"` (an agent
  in a conversation, through `skill_manage`), `"review"` (the background self-improvement
  review), `"curator"` (the maintenance pass), or `"user:<where>"` (a person at `cli`,
  the `dashboard`, or a `chat`). Nothing can change a managed skill without leaving a row
  here, which is what makes a background rewrite something a person can find, read and
  undo - `pepe skill log` prints it, `pepe skill curator rollback` restores the last
  snapshot.

  Best-effort by design (see `Pepe.Skills.Stats`): a ledger write that fails is a warning,
  never a reason a skill change is refused.
  """

  import Ecto.Query, only: [from: 2]

  alias Pepe.Repo
  alias Pepe.Skills.Event
  alias Pepe.Skills.Stats

  @doc "Record `action` on `skill` by `actor`. `detail` is any JSON-encodable map or string."
  @spec log(String.t(), String.t(), String.t(), map() | String.t() | nil) :: :ok
  def log(skill, action, actor, detail \\ nil) do
    record(skill, action, actor, detail)
    :ok
  end

  @doc "Like `log/4`, and returns the new event's id (`nil` when the row could not be written)."
  @spec record(String.t(), String.t(), String.t(), map() | String.t() | nil) :: String.t() | nil
  def record(skill, action, actor, detail \\ nil) do
    Stats.safe(
      fn ->
        id = new_id()

        %Event{}
        |> Event.changeset(%{
          id: id,
          at: System.system_time(:microsecond),
          skill: skill,
          action: action,
          actor: actor,
          detail: encode(detail)
        })
        |> Repo.insert!()

        id
      end,
      nil
    )
  end

  @doc "The most recent events, newest first. `skill` narrows to one skill."
  @spec recent(pos_integer(), String.t() | nil) :: [Event.t()]
  def recent(limit \\ 50, skill \\ nil) do
    query = from(e in Event, order_by: [desc: e.at, desc: e.id], limit: ^limit)
    query = if skill, do: from(e in query, where: e.skill == ^skill), else: query
    Stats.safe(fn -> Repo.all(query) end, [])
  end

  @doc "Every event by `actor` written at or after `at` (a `System.system_time(:microsecond)` value), oldest first."
  @spec since(integer(), String.t()) :: [Event.t()]
  def since(at, actor) when is_integer(at) do
    query = from(e in Event, where: e.at >= ^at and e.actor == ^actor, order_by: [asc: e.at, asc: e.id])
    Stats.safe(fn -> Repo.all(query) end, [])
  end

  @doc "The event with this id, or `nil`."
  @spec get(String.t()) :: Event.t() | nil
  def get(id) when is_binary(id), do: Stats.safe(fn -> Repo.get(Event, id) end, nil)

  @doc "The structured `detail` of an event as a map (`%{}` when it was plain text or empty)."
  @spec detail(Event.t()) :: map()
  def detail(%Event{detail: detail}) when is_binary(detail) do
    case Jason.decode(detail) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  def detail(_), do: %{}

  @doc "Like `describe/1`, led by the event id so a person can name it to `pepe skill undo`."
  @spec describe_with_id(Event.t()) :: String.t()
  def describe_with_id(%Event{} = e), do: "#{e.id}  #{describe(e)}"

  @doc "One line for an event, for CLI and dashboard listings."
  @spec describe(Event.t()) :: String.t()
  def describe(%Event{} = e) do
    unit = if e.at > 10_000_000_000, do: :microsecond, else: :second
    time = e.at |> DateTime.from_unix!(unit) |> Calendar.strftime("%Y-%m-%d %H:%M")
    suffix = if e.detail in [nil, ""], do: "", else: " - " <> String.slice(e.detail, 0, 100)
    "#{time}  #{e.skill}  #{e.action}  (#{e.actor})#{suffix}"
  end

  defp encode(nil), do: nil
  defp encode(text) when is_binary(text), do: text
  defp encode(map) when is_map(map), do: Jason.encode!(map)

  defp new_id, do: 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
