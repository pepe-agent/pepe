defmodule Pepe.Approval do
  @moduledoc """
  A review queue for **autonomous writes**. When `Pepe.Config.review_writes?/0` is on,
  a background job (memory/skill consolidation) that would edit files has its file-tool
  calls *staged* here instead of applied. A human then approves or rejects each one, so a
  hallucinated "fact" or a bad skill edit never persists silently.

  Each pending entry is a small JSON file under `<PEPE_HOME>/pending/`. Approving replays
  the original tool call through `Pepe.Tools`, so it reuses the exact write logic (and
  its workspace path resolution); rejecting just deletes the entry.
  """
  alias Pepe.Config

  @doc "Directory holding staged writes."
  def dir, do: Path.join(Config.home(), "pending")

  @doc "Stage `tool_call` (an OpenAI tool-call map) made by `agent`, returning its id."
  def stage(agent, tool_call, meta \\ %{}) do
    id = 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    entry = %{
      "id" => id,
      "agent" => to_string(agent),
      "tool" => get_in(tool_call, ["function", "name"]),
      "tool_call" => tool_call,
      "at" => System.os_time(:second),
      "meta" => meta
    }

    File.mkdir_p!(dir())
    File.write!(path(id), Jason.encode!(entry))
    {:ok, id, entry}
  end

  @doc "All pending entries, newest first."
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&read(Path.join(dir(), &1)))
        |> Enum.sort_by(& &1["at"], :desc)

      _ ->
        []
    end
  end

  @doc "Fetch one pending entry by id, or nil."
  def get(id), do: read(path(id)) |> List.first()

  @doc "Discard a staged write without applying it."
  def reject(id) do
    case get(id) do
      nil -> {:error, :not_found}
      _ -> File.rm(path(id))
    end
  end

  @doc """
  Apply a staged write: replay its tool call in the agent's workspace context, then
  drop the entry. Returns `{:ok, result}` or `{:error, reason}`.
  """
  def approve(id) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %{"agent" => name, "tool_call" => call} ->
        result = Pepe.Tools.execute(call, %{agent: Config.get_agent(name), cwd: File.cwd!()})
        File.rm(path(id))
        {:ok, result}
    end
  end

  @doc "How many writes are waiting for review."
  def count, do: length(list())

  defp path(id), do: Path.join(dir(), "#{id}.json")

  defp read(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{} = entry} <- Jason.decode(body) do
      [entry]
    else
      _ -> []
    end
  end
end
