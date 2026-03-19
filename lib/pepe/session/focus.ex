defmodule Pepe.Session.Focus do
  @moduledoc """
  Per-session working state: the current **goal** (a persistent objective + status) and
  **plan** (a step checklist) for a conversation. Kept in the disposable `Pepe.Store`,
  keyed by session, so it survives a restart but is regenerable, not a source of truth.

  The `goal` and `update_plan` tools read and write this; surfaces (dashboard, CLI) can
  read it to show what a session is working toward.
  """

  alias Pepe.Store

  @ns :focus

  @type goal :: %{optional(String.t()) => any()}

  @doc "The session's current goal map, or nil."
  def get_goal(nil), do: nil
  def get_goal(key), do: get(key)["goal"]

  @doc "Set the session's goal map."
  def put_goal(key, goal) when is_binary(key), do: update(key, &Map.put(&1, "goal", goal))

  @doc "Clear the session's goal."
  def clear_goal(key) when is_binary(key), do: update(key, &Map.delete(&1, "goal"))

  @doc "The session's current plan (a list of step maps), or nil."
  def get_plan(nil), do: nil
  def get_plan(key), do: get(key)["plan"]

  @doc "Set the session's plan (a list of `%{\"title\", \"status\"}` steps)."
  def put_plan(key, steps) when is_binary(key), do: update(key, &Map.put(&1, "plan", steps))

  @doc "Clear the session's plan."
  def clear_plan(key) when is_binary(key), do: update(key, &Map.delete(&1, "plan"))

  defp get(key), do: Store.get(@ns, key) || %{}

  defp update(key, fun) do
    new = fun.(get(key))
    Store.put(@ns, key, new)
    new["goal"] || new["plan"] || new
  end
end
