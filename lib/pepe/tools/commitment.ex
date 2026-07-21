defmodule Pepe.Tools.Commitment do
  @moduledoc """
  List, confirm, or cancel a **commitment** - a follow-up noticed automatically from
  conversation (see `Pepe.Agent.CommitmentExtract`), not created by hand. Use this when
  the user answers a "did you want me to remember this?" question, or asks what's
  still owed.

  Actions: `list`, `confirm`, `cancel`.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Commitments.DueDate
  alias Pepe.Config
  alias Pepe.Config.Commitment

  @impl true
  def name, do: "commitment"

  @impl true
  def spec do
    function(
      "commitment",
      """
      List, confirm, or cancel a commitment - a follow-up noticed automatically from \
      conversation, not one you created yourself. Use `confirm` when the user answers \
      yes to a "did you want me to remember this?" question you were sent, or `cancel` \
      when they say no. `list` shows what's currently tracked.

      actions:
      - list: show active commitments (awaiting confirmation or scheduled).
      - confirm: needs `id`. Promotes an awaiting-confirmation commitment to scheduled. \
        If its due time never resolved, also pass `due_when` (e.g. "tomorrow", "Friday").
      - cancel: needs `id`.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(list confirm cancel), "description" => "What to do."},
          "id" => %{"type" => "string", "description" => "Commitment id (confirm/cancel)."},
          "due_when" => %{
            "type" => "string",
            "description" => "For confirm, only if the due time didn't resolve: a relative phrase like \"tomorrow\" or \"Friday\"."
          }
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => "list"}, _ctx), do: {:ok, render_list(active())}
  def run(%{"action" => "confirm", "id" => id} = args, _ctx), do: confirm(id, args["due_when"])
  def run(%{"action" => "cancel", "id" => id}, _ctx), do: cancel(id)
  def run(%{"action" => action}, _ctx) when action in ["confirm", "cancel"], do: {:error, "#{action} needs an `id`"}

  def run(%{"action" => action}, _ctx) when is_binary(action) do
    {:error,
     "\"#{action}\" isn't a real action here - only list, confirm, cancel exist. There is " <>
       "no create: a commitment is never made by calling this tool, it's noticed on its own " <>
       "right after your reply. To promise a follow-up, just say so in your reply, plainly, " <>
       "as you normally would - no tool call needed for that."}
  end

  def run(_args, _ctx), do: {:error, "commitment needs an `action`"}

  defp confirm(id, due_when) do
    case Config.get_commitment(id) do
      nil ->
        {:error, "no commitment with id #{id}"}

      %Commitment{due_at: due_at} = c when is_integer(due_at) ->
        Config.put_commitment(%{c | state: "scheduled"})
        {:ok, "Confirmed. I'll follow up on \"#{c.text}\"."}

      %Commitment{} = c ->
        resolve_and_confirm(c, due_when)
    end
  end

  defp resolve_and_confirm(c, due_when) do
    phrase = blank_to_nil(due_when) || c.due_when

    case phrase && DueDate.resolve(phrase, System.system_time(:second)) do
      when_at when is_integer(when_at) ->
        Config.put_commitment(%{c | state: "scheduled", due_when: phrase, due_at: when_at})
        {:ok, "Confirmed. I'll follow up on \"#{c.text}\"."}

      _ ->
        {:error, "still need a clear due time (e.g. \"tomorrow\", \"Friday\") - pass `due_when`"}
    end
  end

  defp cancel(id) do
    case Config.get_commitment(id) do
      nil ->
        {:error, "no commitment with id #{id}"}

      _ ->
        Config.delete_commitment(id)
        {:ok, "Commitment #{id} cancelled."}
    end
  end

  defp active, do: Enum.filter(Config.commitments(), &(&1.state in ["awaiting_confirmation", "scheduled"]))

  defp render_list([]), do: "No active commitments."
  defp render_list(commitments), do: Enum.map_join(commitments, "\n\n", &describe/1)

  defp describe(%Commitment{} = c) do
    [
      "• #{c.id} - #{c.text} (#{c.state})",
      "  who: #{c.origin_type} · due: #{c.due_when || "unresolved"}"
    ]
    |> Enum.join("\n")
  end

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v
end
