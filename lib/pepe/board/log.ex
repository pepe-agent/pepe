defmodule Pepe.Board.Log do
  @moduledoc """
  Append-only audit trail for board cards: one JSONL file per card under
  `<PEPE_HOME>/data/board_logs/<id>.jsonl`. Every transition (created, claimed, completed,
  blocked, ...) and every comment records a line, mirroring `Pepe.Cron.Log`.
  """

  alias Pepe.Config

  @doc "Directory holding the per-card audit logs."
  def dir, do: Path.join([Config.home(), "data", "board_logs"])

  @doc "Append one entry for card `id`. `event` is a short tag (\"claimed\", \"completed\", ...); `extra` is event-specific detail."
  @spec append(String.t(), String.t(), map()) :: :ok
  def append(id, event, extra \\ %{}) do
    File.mkdir_p!(dir())

    entry = %{
      "at" => System.system_time(:second),
      "event" => event
    }

    entry = Map.merge(entry, clip(extra))

    File.write!(path(id), Jason.encode!(entry) <> "\n", [:append])
    :ok
  end

  @doc "Most recent `limit` entries for card `id`, newest first."
  @spec tail(String.t(), non_neg_integer()) :: [map()]
  def tail(id, limit \\ 50) do
    case File.read(path(id)) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reverse()
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  @doc "Delete a card's audit log (called when the card itself, or its board, is removed)."
  def delete(id) do
    File.rm(path(id))
    :ok
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp path(id), do: Path.join(dir(), Base.url_encode64(id, padding: false) <> ".jsonl")

  # Keep any free-text detail (a comment, a completion result) small in the log file.
  defp clip(map) do
    Map.new(map, fn
      {k, v} when is_binary(v) and byte_size(v) > 4000 -> {k, String.slice(v, 0, 4000) <> "..."}
      {k, v} -> {k, v}
    end)
  end
end
