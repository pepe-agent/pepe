defmodule Pepe.Agent.SessionPersistence do
  @moduledoc """
  File-backed persistence for live sessions - one JSON file per session under
  `<PEPE_HOME>/data/sessions/`, so conversations survive a restart.

  Files are written on every change. Being plain files (not a DB) makes them
  durable against an abrupt kill or the machine sleeping - there's no log to flush -
  and trivial to inspect or delete. This is the disposable tier: configs remain the
  source of truth; dropping this directory only loses in-progress conversations.

  A session file also carries an optional **pending** marker: the user text of a
  turn that was in flight when the process went down. `mark_pending/2` writes it
  right before a turn starts; every normal `save/3` (a turn completing, `/new`, ...)
  implicitly clears it, since at that point nothing is in flight anymore. A pending
  marker surviving to the next boot is exactly the signal that turn never finished -
  see `Pepe.Agent.SessionSupervisor.restore/0`.
  """

  alias Pepe.Config

  @doc "The directory holding the per-session JSON files."
  @spec dir() :: String.t()
  def dir, do: Path.join([Config.home(), "data", "sessions"])

  @doc "Write a session's `(agent, messages)` to its file. Clears any pending marker."
  @spec save(String.t(), String.t() | nil, [map()]) :: :ok | {:error, term()}
  def save(key, agent_name, messages) do
    write(key, agent_name, messages, nil)
  end

  @doc """
  Mark a turn as in flight, just before running it - keeps the last-saved
  agent/messages as-is, only sets `pending`.
  """
  @spec mark_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_pending(key, text) do
    {agent_name, messages} =
      case load(key) do
        {:ok, agent, messages, _pending} -> {agent, messages}
        :error -> {nil, []}
      end

    write(key, agent_name, messages, text)
  end

  @doc "Clear a session's pending marker without touching its history."
  @spec clear_pending(String.t()) :: :ok | {:error, term()}
  def clear_pending(key) do
    case load(key) do
      {:ok, agent, messages, _pending} -> save(key, agent, messages)
      :error -> :ok
    end
  end

  defp write(key, agent_name, messages, pending) do
    File.mkdir_p!(dir())
    data = %{"key" => key, "agent_name" => agent_name, "messages" => messages, "pending" => pending}
    File.write(path(key), Jason.encode!(data))
  end

  @doc "Load a session's `{agent, messages, pending}`, or `:error` if none/unreadable."
  @spec load(String.t()) :: {:ok, String.t() | nil, [map()], String.t() | nil} | :error
  def load(key) do
    with {:ok, body} <- File.read(path(key)),
         {:ok, %{"agent_name" => agent, "messages" => messages} = data} when is_list(messages) <-
           Jason.decode(body) do
      {:ok, agent, messages, data["pending"]}
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

  @doc """
  All persisted sessions as `{key, agent_name, pending}` (for restore on boot) -
  `pending` is the interrupted turn's text, or `nil` if the session ended cleanly.
  """
  @spec all() :: [{String.t(), String.t() | nil, String.t() | nil}]
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
      {:ok, %{"key" => key} = data} -> [{key, data["agent_name"], data["pending"]}]
      _ -> []
    end
  rescue
    _ -> []
  end

  # A filesystem-safe filename for any session key (e.g. "telegram:42", "web:3").
  defp path(key), do: Path.join(dir(), Base.url_encode64(key, padding: false) <> ".json")
end
