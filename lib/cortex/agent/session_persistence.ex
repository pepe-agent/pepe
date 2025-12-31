defmodule Cortex.Agent.SessionPersistence do
  @moduledoc """
  File-backed persistence for live sessions — one JSON file per session under
  `<CORTEX_HOME>/data/sessions/`, so conversations survive a restart.

  Files are written on every change. Being plain files (not a DB) makes them
  durable against an abrupt kill or the machine sleeping — there's no log to flush —
  and trivial to inspect or delete. This is the disposable tier: configs remain the
  source of truth; dropping this directory only loses in-progress conversations.
  """

  alias Cortex.Config

  @doc "The directory holding the per-session JSON files."
  @spec dir() :: String.t()
  def dir, do: Path.join([Config.home(), "data", "sessions"])

  @doc "Write a session's `(agent, messages)` to its file."
  @spec save(String.t(), String.t() | nil, [map()]) :: :ok | {:error, term()}
  def save(key, agent_name, messages) do
    File.mkdir_p!(dir())
    data = %{"key" => key, "agent_name" => agent_name, "messages" => messages}
    File.write(path(key), Jason.encode!(data))
  end

  @doc "Load a session's `{agent, messages}`, or `:error` if none/unreadable."
  @spec load(String.t()) :: {:ok, String.t() | nil, [map()]} | :error
  def load(key) do
    with {:ok, body} <- File.read(path(key)),
         {:ok, %{"agent_name" => agent, "messages" => messages}} when is_list(messages) <-
           Jason.decode(body) do
      {:ok, agent, messages}
    else
      _ -> :error
    end
  end

  @doc "Delete a session's file."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    _ = File.rm(path(key))
    :ok
  end

  @doc "All persisted sessions as `{key, agent_name}` (for restore on boot)."
  @spec all() :: [{String.t(), String.t() | nil}]
  def all do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(&read_keyed/1)

      _ ->
        []
    end
  end

  defp read_keyed(file) do
    case Jason.decode(File.read!(Path.join(dir(), file))) do
      {:ok, %{"key" => key} = data} -> [{key, data["agent_name"]}]
      _ -> []
    end
  rescue
    _ -> []
  end

  # A filesystem-safe filename for any session key (e.g. "telegram:42", "web:3").
  defp path(key), do: Path.join(dir(), Base.url_encode64(key, padding: false) <> ".json")
end
