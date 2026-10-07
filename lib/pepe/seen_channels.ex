defmodule Pepe.SeenChannels do
  @moduledoc """
  The channels, groups and direct messages each connection has heard from.

  A webhook connection (a Slack workspace, a Discord server) and a Telegram bot are each one
  card on the Channels page, and an operator looking at that card wants to know where it
  lives: which channels the bot is in, which of them answer without a mention, which have
  their own trainers. Nothing else records that. A session key names the provider, the agent
  and the channel, never the connection, so two connections on one agent could not be told
  apart from the sessions alone.

  So every inbound message records its channel here, at the door and before the mention
  gate, so a channel the bot only listens in is listed too. One row per connection and
  channel id, with the provider, whether it is a direct message or a group, a display name
  when the platform gave one cheaply, and when it was first and last heard from. The
  connection is a webhook slug or a Telegram bot name.

  Operational data that grows with use, so it lives in `Pepe.Repo`. The refresh of
  `last_seen` is throttled in memory (one write per channel per minute at most) so a busy
  channel never turns every message into a SQLite write, and a write that fails is logged
  and dropped: nothing here may ever slow or break the message it rides on.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Pepe.Repo
  alias Pepe.SeenChannels.Channel

  @table __MODULE__
  @refresh_s 60
  @kinds ["dm", "group"]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Record that `channel` on `connection` was just heard from. The first time, the row is
  created and `:new` returned; afterwards `last_seen` is refreshed (`:seen`), at most once a
  minute per channel (`:skipped` in between). `opts`: `:kind` (`"dm"` or `"group"`), `:name`
  (a display name; it replaces the stored one only when given), `:now` (unix seconds, the
  time source for both the row and the throttle).

  Never raises. Without the repo running (a replay from a one-shot command) nothing is
  recorded; a write that fails is logged and answered with `:error`.
  """
  @spec touch(String.t(), String.t(), String.t(), keyword()) :: :new | :seen | :skipped | :error
  def touch(connection, provider, channel, opts \\ [])
      when is_binary(connection) and is_binary(provider) and is_binary(channel) do
    now = opts[:now] || System.os_time(:second)

    cond do
      not repo_up?() -> :error
      not due?(connection, channel, now) -> :skipped
      true -> write(connection, provider, channel, now, opts)
    end
  end

  @doc "Store the display name a lookup found for a channel. A no-op for a channel never heard from."
  @spec put_name(String.t(), String.t(), String.t()) :: :ok
  def put_name(connection, channel, name) when is_binary(name) do
    if repo_up?() do
      Repo.update_all(from(c in Channel, where: c.connection == ^connection and c.channel == ^channel), set: [name: name])
    end

    :ok
  end

  @doc """
  Store the name the operator gave a channel (`nil` clears it), kept apart from the provider's
  own `name` so a later refresh never overwrites it. A no-op for a channel never heard from.
  """
  @spec put_label(String.t(), String.t(), String.t() | nil) :: :ok
  def put_label(connection, channel, label) do
    if repo_up?() do
      Repo.update_all(from(c in Channel, where: c.connection == ^connection and c.channel == ^channel),
        set: [label: Pepe.Labels.clean(label)]
      )
    end

    :ok
  end

  @doc "One channel of a connection, or `nil` when it was never heard from (or the repo is down)."
  @spec get(String.t(), String.t()) :: Channel.t() | nil
  def get(connection, channel) do
    if repo_up?(), do: Repo.get_by(Channel, connection: connection, channel: channel)
  end

  @doc """
  Every channel this connection has heard from, the most recent first. Empty without the repo
  running, so a page that lists them renders either way.
  """
  @spec list(String.t()) :: [Channel.t()]
  def list(connection) do
    if repo_up?() do
      Repo.all(from(c in Channel, where: c.connection == ^connection, order_by: [desc: c.last_seen, asc: c.channel]))
    else
      []
    end
  end

  @doc "Forget everything recorded for a connection, when the connection itself is removed."
  @spec delete_connection(String.t()) :: :ok
  def delete_connection(connection) do
    if repo_up?(), do: Repo.delete_all(from(c in Channel, where: c.connection == ^connection))
    :ok
  end

  defp repo_up?, do: not is_nil(Process.whereis(Repo))

  defp due?(connection, channel, now), do: throttle_due?({:channel, connection, channel}, now)

  @doc false
  # The throttle lives in ETS, keyed by this instance's config home as well (two instances in
  # one VM, a test suite, must not share it). Without the table (no supervision tree) every
  # message is due: correctness over economy in a setting that has no traffic anyway. Shared
  # with `Pepe.SeenPeople`, which rides the same table under its own key shape.
  @spec throttle_due?(tuple(), integer()) :: boolean()
  def throttle_due?(what, now) do
    if :ets.whereis(@table) == :undefined do
      true
    else
      key = {Pepe.Config.home(), what}

      case :ets.lookup(@table, key) do
        [{^key, at}] when now - at < @refresh_s ->
          false

        _ ->
          :ets.insert(@table, {key, now})
          true
      end
    end
  end

  defp write(connection, provider, channel, now, opts) do
    exists? = Repo.exists?(from(c in Channel, where: c.connection == ^connection and c.channel == ^channel))
    name = blank(opts[:name])
    kind = if opts[:kind] in @kinds, do: opts[:kind]

    if exists? do
      set = [last_seen: now] ++ if(name, do: [name: name], else: []) ++ if(kind, do: [kind: kind], else: [])
      Repo.update_all(from(c in Channel, where: c.connection == ^connection and c.channel == ^channel), set: set)
      :seen
    else
      Repo.insert!(%Channel{
        connection: connection,
        provider: provider,
        channel: channel,
        name: name,
        kind: kind,
        first_seen: now,
        last_seen: now
      })

      :new
    end
  rescue
    e ->
      Logger.warning("[seen_channels] could not record #{connection}/#{channel}: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[seen_channels] could not record #{connection}/#{channel}: #{inspect(reason)}")
      :error
  end

  defp blank(name) when is_binary(name), do: if(String.trim(name) == "", do: nil, else: String.trim(name))
  defp blank(_name), do: nil

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
