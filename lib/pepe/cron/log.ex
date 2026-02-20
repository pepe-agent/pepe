defmodule Pepe.Cron.Log do
  @moduledoc """
  Append-only run history for scheduled tasks — one JSONL file per cron under
  `<PEPE_HOME>/data/cron_logs/<id>.jsonl`. Every fire (scheduled or forced)
  records a line so the result can be consulted later from the dashboard, the CLI,
  or a chat.
  """

  alias Pepe.Config

  @doc "Directory holding the per-cron run logs."
  def dir, do: Path.join([Config.home(), "data", "cron_logs"])

  @doc """
  Append one run entry for cron `id`. `source` is `:scheduler | :manual | :agent`,
  `ok?` whether it succeeded, `output` the (clipped) result text.
  """
  @spec append(String.t(), atom(), boolean(), String.t()) :: :ok
  def append(id, source, ok?, output) do
    File.mkdir_p!(dir())

    entry = %{
      "at" => System.system_time(:second),
      "source" => to_string(source),
      "ok" => ok?,
      "output" => clip(output)
    }

    File.write!(path(id), Jason.encode!(entry) <> "\n", [:append])
    :ok
  end

  @doc "Most recent `limit` run entries for cron `id`, newest first."
  @spec tail(String.t(), non_neg_integer()) :: [map()]
  def tail(id, limit \\ 20) do
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

  @doc "Delete a cron's run log (called when the cron itself is removed)."
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

  defp clip(text) when is_binary(text) do
    if String.length(text) > 4000, do: String.slice(text, 0, 4000) <> "…", else: text
  end

  defp clip(text), do: to_string(text)
end
