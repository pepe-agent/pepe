defmodule Pepe.SeenPeople do
  @moduledoc """
  The people who have written in each channel a connection has heard from.

  "Who can train" is a list of people, and nobody wants to look up and type platform ids to
  build one. So every inbound message written by a person records who wrote it, next to the
  channel it came in (`Pepe.SeenChannels`): one row per connection, channel and person id,
  with a display name when the platform gave one cheaply, and when they were first and last
  heard. The trainer pickers on the Channels page offer exactly these people: everyone heard
  anywhere on the connection for the connection's list, those heard in one channel for that
  channel's.

  People only: a message from a bot or an integration, or one with no sender at all, is
  never recorded. The connection is a webhook slug or a Telegram bot name.

  Operational data that grows with use, so it lives in `Pepe.Repo`, with the same
  guarantees as the channels: the `last_seen` refresh is throttled in memory to one write
  per person per minute, nothing is written without the repo, and a failed write only logs.
  """

  import Ecto.Query

  require Logger

  alias Pepe.Repo
  alias Pepe.SeenPeople.Person

  @doc """
  Record that `person` just wrote in `channel` on `connection`. `:new` the first time, `:seen`
  when `last_seen` was refreshed, `:skipped` within the throttle, `:error` when nothing could
  be written. `opts`: `:name` (a display name; replaces the stored one only when given),
  `:now` (unix seconds). Never raises.
  """
  @spec touch(String.t(), String.t(), String.t(), keyword()) :: :new | :seen | :skipped | :error
  def touch(connection, channel, person, opts \\ [])
      when is_binary(connection) and is_binary(channel) and is_binary(person) do
    now = opts[:now] || System.os_time(:second)

    cond do
      not repo_up?() -> :error
      not Pepe.SeenChannels.throttle_due?({:person, connection, channel, person}, now) -> :skipped
      true -> write(connection, channel, person, now, opts)
    end
  end

  @doc "Store the display name a lookup found for a person, in every channel they were heard in."
  @spec put_name(String.t(), String.t(), String.t()) :: :ok
  def put_name(connection, person, name) when is_binary(name) do
    if repo_up?() do
      Repo.update_all(from(p in Person, where: p.connection == ^connection and p.person == ^person), set: [name: name])
    end

    :ok
  end

  @doc """
  Store the name the operator gave a person (`nil` clears it), on every channel of the
  connection they were heard in, so it follows them. Kept apart from the provider's `name`.
  """
  @spec put_label(String.t(), String.t(), String.t() | nil) :: :ok
  def put_label(connection, person, label) do
    if repo_up?() do
      Repo.update_all(from(p in Person, where: p.connection == ^connection and p.person == ^person),
        set: [label: Pepe.Labels.clean(label)]
      )
    end

    :ok
  end

  @doc "What is known about one person on a connection (any channel), or `nil`."
  @spec get(String.t(), String.t()) :: Person.t() | nil
  def get(connection, person) do
    if repo_up?(), do: Repo.one(from(p in Person, where: p.connection == ^connection and p.person == ^person, limit: 1))
  end

  @doc """
  Everyone heard on this connection, or in one channel of it, most recently heard first. Empty
  without the repo running, so a page that lists them renders either way.
  """
  @spec list(String.t(), String.t() | nil) :: [Person.t()]
  def list(connection, channel \\ nil) do
    cond do
      not repo_up?() ->
        []

      is_nil(channel) ->
        Repo.all(from(p in Person, where: p.connection == ^connection, order_by: [desc: p.last_seen, asc: p.person]))

      true ->
        Repo.all(
          from(p in Person,
            where: p.connection == ^connection and p.channel == ^channel,
            order_by: [desc: p.last_seen, asc: p.person]
          )
        )
    end
  end

  @doc "Forget everyone recorded for a connection, when the connection itself is removed."
  @spec delete_connection(String.t()) :: :ok
  def delete_connection(connection) do
    if repo_up?(), do: Repo.delete_all(from(p in Person, where: p.connection == ^connection))
    :ok
  end

  defp repo_up?, do: not is_nil(Process.whereis(Repo))

  defp write(connection, channel, person, now, opts) do
    scope = from(p in Person, where: p.connection == ^connection and p.channel == ^channel and p.person == ^person)
    name = blank(opts[:name])

    if Repo.exists?(scope) do
      Repo.update_all(scope, set: [last_seen: now] ++ if(name, do: [name: name], else: []))
      :seen
    else
      # The label the operator gave this person elsewhere on the connection follows them here.
      label = Repo.one(from(p in Person, where: p.connection == ^connection and p.person == ^person, select: p.label, limit: 1))

      Repo.insert!(%Person{
        connection: connection,
        channel: channel,
        person: person,
        name: name,
        label: label,
        first_seen: now,
        last_seen: now
      })

      :new
    end
  rescue
    e ->
      Logger.warning("[seen_people] could not record #{connection}/#{channel}/#{person}: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[seen_people] could not record #{connection}/#{channel}/#{person}: #{inspect(reason)}")
      :error
  end

  defp blank(name) when is_binary(name), do: if(String.trim(name) == "", do: nil, else: String.trim(name))
  defp blank(_name), do: nil
end
