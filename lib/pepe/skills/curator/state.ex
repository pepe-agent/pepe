defmodule Pepe.Skills.Curator.State do
  @moduledoc """
  What the curator remembers between runs: when it last ran, whether a person paused it, how
  the last run went and where its report is. A small JSON file beside the skills
  (`<PEPE_HOME>/skills/.curator/state.json`; the dot keeps it out of the skills index).

  Operational state, not configuration: `pepe skill curator pause` and a run rewrite it, and
  it is safe to delete (the next observation seeds it again and waits one interval, so a fresh
  install never rewrites a library on its first tick).
  """

  alias Pepe.Skills

  @base %{
    "last_run_at" => nil,
    "last_run_duration_ms" => nil,
    "last_run_summary" => nil,
    "last_report" => nil,
    "paused" => false,
    "run_count" => 0
  }

  @doc "Where the curator keeps its files."
  @spec dir() :: String.t()
  def dir, do: Path.join(Skills.user_dir(), ".curator")

  @doc "Where run reports are written."
  @spec reports_dir() :: String.t()
  def reports_dir, do: Path.join(dir(), "reports")

  defp file, do: Path.join(dir(), "state.json")

  @doc "The saved state, with defaults for anything missing or unreadable."
  @spec load() :: map()
  def load do
    with {:ok, body} <- File.read(file()),
         {:ok, %{} = saved} <- Jason.decode(body) do
      Map.merge(@base, Map.take(saved, Map.keys(@base)))
    else
      _ -> @base
    end
  end

  @doc "Merge `changes` into the saved state."
  @spec update(map()) :: :ok
  def update(changes) when is_map(changes) do
    File.mkdir_p!(dir())
    tmp = file() <> ".tmp"
    File.write!(tmp, Jason.encode!(Map.merge(load(), changes), pretty: true))
    File.rename!(tmp, file())
    :ok
  end

  @spec paused?() :: boolean()
  def paused?, do: load()["paused"] == true

  @spec set_paused(boolean()) :: :ok
  def set_paused(paused?), do: update(%{"paused" => paused?})

  @doc "The last run's time, or `nil` if there was none."
  @spec last_run_at() :: DateTime.t() | nil
  def last_run_at do
    with iso when is_binary(iso) <- load()["last_run_at"],
         {:ok, at, _} <- DateTime.from_iso8601(iso) do
      at
    else
      _ -> nil
    end
  end
end
