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
  right before a turn starts; every normal `save/4` (a turn completing, `/new`, ...)
  implicitly clears it, since at that point nothing is in flight anymore. A pending
  marker surviving to the next boot is exactly the signal that turn never finished -
  see `Pepe.Agent.SessionSupervisor.restore/0`.

  ## PII map at rest

  When redaction hooks are enabled, the persisted `messages` already hold *pseudonyms*
  (inbound hooks redact before anything reaches history). The reversible `pii_map`
  (pseudonym -> real) is persisted alongside so a restored session can put the real
  values back on the way out - without it, a restart makes the agent quote "PERSON_1"
  at the user and re-mint fresh tokens for names it has already seen. This does write the
  real values to the operator's own disk (same trust tier as `config.json` with its
  secret refs); redaction's actual guarantee - that PII never reaches the *provider* -
  is unaffected. Ephemeral (customer-facing) sessions don't persist at all, so nothing
  is written there.
  """

  alias Pepe.Config

  @doc "The directory holding the per-session JSON files."
  @spec dir() :: String.t()
  def dir, do: Path.join([Config.home(), "data", "sessions"])

  @doc "Write a session's `(agent, messages, pii_map)` to its file. Clears any pending marker."
  @spec save(String.t(), String.t() | nil, [map()], [map()]) :: :ok | {:error, term()}
  def save(key, agent_name, messages, pii_map \\ []) do
    write(key, agent_name, messages, pii_map, nil)
  end

  @doc """
  Mark a turn as in flight, just before running it - keeps the last-saved
  agent/messages/pii_map as-is, only sets `pending`.
  """
  @spec mark_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_pending(key, text) do
    {agent_name, messages, pii_map} =
      case load(key) do
        {:ok, agent, messages, pii_map, _pending} -> {agent, messages, pii_map}
        :error -> {nil, [], []}
      end

    write(key, agent_name, messages, pii_map, text)
  end

  @doc "Clear a session's pending marker without touching its history."
  @spec clear_pending(String.t()) :: :ok | {:error, term()}
  def clear_pending(key) do
    case load(key) do
      {:ok, agent, messages, pii_map, _pending} -> save(key, agent, messages, pii_map)
      :error -> :ok
    end
  end

  defp write(key, agent_name, messages, pii_map, pending) do
    File.mkdir_p!(dir())

    data = %{
      "key" => key,
      "agent_name" => agent_name,
      "messages" => messages,
      "pii_map" => pii_map,
      "pending" => pending
    }

    File.write(path(key), Jason.encode!(data))
  end

  @doc "Load a session's `{agent, messages, pii_map, pending}`, or `:error` if none/unreadable."
  @spec load(String.t()) :: {:ok, String.t() | nil, [map()], [map()], String.t() | nil} | :error
  def load(key) do
    with {:ok, body} <- File.read(path(key)),
         {:ok, %{"agent_name" => agent, "messages" => messages} = data} when is_list(messages) <-
           Jason.decode(body) do
      pii_map = if is_list(data["pii_map"]), do: data["pii_map"], else: []
      {:ok, agent, messages, pii_map, data["pending"]}
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
