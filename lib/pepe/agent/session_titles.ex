defmodule Pepe.Agent.SessionTitles do
  @moduledoc """
  Optional human labels for sessions, shown in the dashboard sidebar and set with the
  `/name` command. A small `key => title` map persisted next to the session files, kept
  out of the per-turn session JSON so the hot save path never touches it. Disposable:
  losing it only reverts a session to showing its key.
  """
  alias Pepe.Config

  @doc "The title for `key`, or `nil` when it has none."
  def get(key), do: Map.get(all(), to_string(key))

  @doc "All labels as a `key => title` map."
  def all do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Set the label for `key`; an empty/blank title clears it. Returns `:ok`."
  def set(key, title) do
    key = to_string(key)
    title = String.trim(to_string(title))
    map = all()

    map = if title == "", do: Map.delete(map, key), else: Map.put(map, key, title)
    write(map)
  end

  @doc "Forget the label for `key` (e.g. when its session is deleted)."
  def delete(key), do: all() |> Map.delete(to_string(key)) |> write()

  defp write(map) do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    File.write(path, Jason.encode!(map))
    :ok
  end

  defp path, do: Path.join([Config.home(), "data", "session_titles.json"])
end
