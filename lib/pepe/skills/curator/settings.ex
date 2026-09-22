defmodule Pepe.Skills.Curator.Settings do
  @moduledoc """
  The curator's settings, under `"skills" => "curator"` in `config.json` (next to the other
  skill settings of `Pepe.Skills.Settings`). Every key is optional; a missing one reads as
  its default.

    * `enabled` - the curator runs at all (default on: with no agent-written skills it has
      nothing to do, and what it does to one is recoverable).
    * `interval_hours` - the shortest gap between runs (default a week).
    * `min_idle_hours` - how long nothing may have happened in any conversation before a run
      starts (default 2).
    * `stale_after_days` / `archive_after_days` - how long an agent-written skill may sit
      unused before it is marked stale, then archived (defaults 14 and 30).
    * `consolidate` - also run the model pass that merges overlapping skills into broader ones
      (default off: it costs a model run, so it is opt-in, and it can be requested once with
      `pepe skill curator run --consolidate` without turning it on).

  Nothing here reaches skills a person wrote, installed skills, bundled skills or pinned ones:
  that is `Pepe.Skills.Ownership`'s rule, not a setting.
  """

  alias Pepe.Config

  @defaults %{
    "enabled" => true,
    "interval_hours" => 168,
    "min_idle_hours" => 2,
    "stale_after_days" => 14,
    "archive_after_days" => 30,
    "consolidate" => false
  }

  @booleans ~w(enabled consolidate)
  @integers ~w(interval_hours min_idle_hours stale_after_days archive_after_days)

  @doc "Every setting with its current value."
  @spec all() :: %{String.t() => boolean() | non_neg_integer()}
  def all, do: Map.new(@defaults, fn {key, default} -> {key, get(key, default)} end)

  @doc "The keys that can be set."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@defaults) |> Enum.sort()

  @doc "One setting's current value."
  @spec get(String.t()) :: boolean() | non_neg_integer()
  def get(key) when is_map_key(@defaults, key), do: get(key, Map.fetch!(@defaults, key))

  defp get(key, default) do
    case section()[key] do
      value when is_boolean(value) and key in @booleans -> value
      value when is_integer(value) and value >= 0 and key in @integers -> value
      _ -> default
    end
  end

  def enabled?, do: get("enabled")
  def consolidate?, do: get("consolidate")
  def interval_hours, do: get("interval_hours")
  def min_idle_hours, do: get("min_idle_hours")
  def stale_after_days, do: get("stale_after_days")
  def archive_after_days, do: get("archive_after_days")

  @doc """
  Set `key`. Accepts a value of the right type or its text form (`"true"`, `"7"`), refuses an
  unknown key, and keeps the archive threshold at or above the stale one.
  """
  @spec put(String.t(), term()) :: :ok | {:error, String.t()}
  def put(key, value) do
    with {:ok, key} <- check_key(key),
         {:ok, value} <- cast(key, value),
         :ok <- check_order(key, value) do
      Config.update(fn config -> update_in(config, ["skills"], &put_in_curator(&1, key, value)) end)
      :ok
    end
  end

  defp check_key(key) when is_map_key(@defaults, key), do: {:ok, key}
  defp check_key(key), do: {:error, "unknown curator setting '#{key}'; use one of: #{Enum.join(keys(), ", ")}."}

  defp cast(key, value) when key in @booleans do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "on", "yes", "1"] -> {:ok, true}
      v when v in ["false", "off", "no", "0"] -> {:ok, false}
      _ -> {:error, "#{key} is on or off."}
    end
  end

  defp cast(key, value) when key in @integers do
    case value do
      v when is_integer(v) and v >= 0 -> {:ok, v}
      v when is_binary(v) -> cast_integer(key, Integer.parse(v))
      _ -> {:error, "#{key} is a whole number, zero or more."}
    end
  end

  defp cast_integer(_key, {n, ""}) when n >= 0, do: {:ok, n}
  defp cast_integer(key, _), do: {:error, "#{key} is a whole number, zero or more."}

  defp check_order("stale_after_days", value) do
    if value <= get("archive_after_days"), do: :ok, else: {:error, "stale_after_days cannot be longer than archive_after_days."}
  end

  defp check_order("archive_after_days", value) do
    cond do
      value < 1 -> {:error, "archive_after_days must be at least 1 (0 would archive an agent-written skill the moment it's created)."}
      value < get("stale_after_days") -> {:error, "archive_after_days cannot be shorter than stale_after_days."}
      true -> :ok
    end
  end

  defp check_order(_key, _value), do: :ok

  defp put_in_curator(skills, key, value) do
    skills = skills || %{}
    Map.put(skills, "curator", Map.put(Map.get(skills, "curator") || %{}, key, value))
  end

  defp section do
    with %{} = skills <- Config.load()["skills"],
         %{} = curator <- skills["curator"] do
      curator
    else
      _ -> %{}
    end
  end
end
