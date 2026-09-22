defmodule Pepe.Gateways.Discord do
  @moduledoc """
  A Discord connection that receives ordinary messages, over the gateway.

  The Interactions endpoint (`Pepe.Webhooks.Discord`) only ever sees slash commands. A
  message typed in a channel, a photo dropped into it, a voice message recorded in it, a
  direct message to the bot: none of those are interactions, and Discord delivers them only
  over its gateway, a WebSocket the bot holds open. This process is that connection, for one
  webhook connection that turned `receive_channel_messages` on and gave a `bot_token`.

  It does the protocol and nothing else. Each `MESSAGE_CREATE` is handed to
  `Pepe.Webhooks.handle_gateway_event/2`, which parses, gates, orders and answers it exactly
  as it would a webhook `POST`, so an attachment goes through the same
  `Pepe.Webhooks.Media` door (voice note to transcript, document to text, image to the model),
  the reply goes back with the bot's token, and a message from a person who is not allowed is
  ignored by the same allowlist.

  What it takes care of, because a connection that stays up for weeks has to:

    * **Heartbeats and zombies.** It heartbeats on the interval Discord asks for, and a
      heartbeat that was never acknowledged is a dead connection: it is dropped and reopened.
    * **Resuming.** A dropped connection picks its session back up (`RESUME`), so nothing said
      in the gap is lost; a session Discord no longer knows starts over.
    * **Backing off.** Reconnects wait 1s, then 2s, 4s, ... up to a minute, with jitter, so an
      outage on either side is not made worse by a bot retrying in a tight loop.
    * **Not retrying what cannot work.** A bad token, or an intent the app may not use, is
      logged with the reason and ends the connection instead of repeating the same refusal.
      The Message Content intent is the common one: without it enabled in the Developer
      Portal, Discord closes the connection with 4014, and the bot reconnects *without* the
      intent, so DMs and @mentions (which Discord always delivers in full) keep working.

  Only bots-are-not-answered is decided here: messages written by a bot (this one included)
  are dropped before anything else, so two bots in a channel cannot talk each other into a
  loop. Everything about who may be answered, and when, is the provider's and
  `Pepe.Webhooks`' business.
  """

  use GenServer, restart: :transient

  require Logger

  alias Pepe.Config
  alias Pepe.Gateways.Discord.Protocol
  alias Pepe.Webhooks.Discord, as: Provider

  # A message type that carries something somebody said: 0 is a plain message, 19 a reply.
  @message_types [0, 19]

  # How long a freshly opened socket has to say hello before it is written off.
  @hello_deadline_ms 30_000

  defstruct slug: nil,
            conn: nil,
            ref: nil,
            websocket: nil,
            status: :closed,
            upgrade: %{},
            seq: nil,
            session_id: nil,
            resume_url: nil,
            bot_id: nil,
            interval: nil,
            acked?: true,
            heartbeat: nil,
            attempt: 0,
            content?: true

  @doc "Whether this webhook connection asks for the gateway and has what it needs to open one."
  @spec active?(map()) :: boolean()
  def active?(%{"provider" => "discord"} = entry), do: Provider.gateway?(entry) and is_binary(token(entry))
  def active?(_entry), do: false

  @doc false
  def token(entry) do
    case Config.interpolate((entry["config"] || %{})["bot_token"]) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  def start_link(slug), do: GenServer.start_link(__MODULE__, slug)

  @impl true
  def init(slug) do
    send(self(), :connect)
    {:ok, %__MODULE__{slug: slug}}
  end

  ###
  ### connecting
  ###

  @impl true
  def handle_info(:connect, state) do
    with {:ok, entry} <- fetch_entry(state.slug),
         {:ok, url} <- gateway_url(state, token(entry)),
         {:ok, state} <- open(state, url) do
      {:noreply, state}
    else
      {:fatal, reason} ->
        Logger.error("[discord:#{state.slug}] #{reason}; not reconnecting")
        {:stop, :normal, state}

      {:retry, reason} ->
        Logger.warning("[discord:#{state.slug}] could not connect: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info({:hello_deadline, ref}, %{ref: ref, interval: nil} = state) do
    Logger.warning("[discord:#{state.slug}] Discord never said hello; reconnecting")
    settle(reconnect(state, :resume))
  end

  def handle_info({:hello_deadline, _ref}, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{acked?: false} = state) do
    Logger.warning("[discord:#{state.slug}] heartbeat was never acknowledged; reconnecting")
    settle(reconnect(state, :resume))
  end

  def handle_info(:heartbeat, state) do
    state = send_frame(state, Protocol.heartbeat(state.seq))
    settle(schedule_heartbeat(%{state | acked?: false}, state.interval))
  end

  # Whatever the socket says: the upgrade answer, frames, or the connection going away.
  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> settle(Enum.reduce(responses, %{state | conn: conn}, &on_response/2))
      {:error, conn, reason, _responses} -> settle(closed(%{state | conn: conn}, reason))
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A helper returned either a state to carry on with or a decision to end the process.
  defp settle({:stop, _state} = stop), do: stop_tuple(stop)
  defp settle(%__MODULE__{} = state), do: {:noreply, state}

  defp stop_tuple({:stop, state}), do: {:stop, :normal, state}

  defp fetch_entry(slug) do
    case Config.get_webhook(slug) do
      %{"provider" => "discord"} = entry ->
        cond do
          not Provider.gateway?(entry) -> {:fatal, "the gateway was turned off for this connection"}
          is_nil(token(entry)) -> {:fatal, "no bot token is configured"}
          true -> {:ok, entry}
        end

      _ ->
        {:fatal, "the connection no longer exists"}
    end
  end

  # A session that can be resumed goes back to the URL Discord gave for it; a new one asks
  # Discord where to connect (and how many session starts are left, so a bot in a restart
  # loop is stopped before Discord bans the token for it).
  defp gateway_url(%{resume_url: url}, _token) when is_binary(url), do: {:ok, url}

  defp gateway_url(_state, token) do
    case Req.get(Provider.api() <> "/gateway/bot", headers: [{"authorization", "Bot " <> token}], retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"url" => url} = body}} ->
        case get_in(body, ["session_start_limit", "remaining"]) do
          0 -> {:retry, {:session_start_limit, get_in(body, ["session_start_limit", "reset_after"])}}
          _ -> {:ok, url}
        end

      {:ok, %{status: 401}} ->
        {:fatal, Protocol.explain(4004)}

      {:ok, %{status: status}} ->
        {:retry, {:http, status}}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp open(state, url) do
    uri = URI.parse(url)
    secure? = uri.scheme in ["wss", "https"]
    port = uri.port || if(secure?, do: 443, else: 80)
    path = (uri.path in [nil, ""] && "/") || uri.path
    path = path <> "?v=10&encoding=json"

    with {:ok, conn} <- Mint.HTTP.connect(if(secure?, do: :https, else: :http), uri.host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(if(secure?, do: :wss, else: :ws), conn, path, []) do
      # A connection that never says hello (the upgrade is accepted and then nothing) has no
      # heartbeat to expose it, so it gets a deadline of its own.
      Process.send_after(self(), {:hello_deadline, ref}, @hello_deadline_ms)
      {:ok, %{state | conn: conn, ref: ref, status: :upgrading, upgrade: %{}, websocket: nil, interval: nil}}
    else
      {:error, reason} -> {:retry, reason}
      {:error, _conn, reason} -> {:retry, reason}
    end
  end

  ###
  ### what the socket said
  ###

  defp on_response({:status, ref, status}, %{ref: ref} = state), do: put_in(state.upgrade[:status], status)
  defp on_response({:headers, ref, headers}, %{ref: ref} = state), do: put_in(state.upgrade[:headers], headers)

  defp on_response({:done, ref}, %{ref: ref, status: :upgrading} = state), do: upgraded(state)

  # Discord speaks first (Hello), and over a fast link its first frame can ride in the same
  # packet as the upgrade answer, where it is reported before the answer is marked done.
  # Finishing the upgrade at that point is what keeps that first frame from being lost.
  defp on_response({:data, ref, _data} = response, %{ref: ref, status: :upgrading} = state) do
    case upgraded(state) do
      %__MODULE__{status: :open} = state -> on_response(response, state)
      other -> other
    end
  end

  defp on_response({:data, ref, data}, %{ref: ref, status: :open} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} -> Enum.reduce(frames, %{state | websocket: websocket}, &on_frame/2)
      {:error, websocket, reason} -> closed(%{state | websocket: websocket}, {:decode, reason})
    end
  end

  defp on_response(_response, state), do: state

  defp upgraded(state) do
    case Mint.WebSocket.new(state.conn, state.ref, state.upgrade[:status], state.upgrade[:headers] || []) do
      {:ok, conn, websocket} -> %{state | conn: conn, websocket: websocket, status: :open}
      {:error, conn, reason} -> closed(%{state | conn: conn}, {:upgrade, reason})
    end
  end

  defp on_frame(_frame, {:stop, _} = stop), do: stop

  defp on_frame({:text, text}, state) do
    case Protocol.decode(text) do
      {:ok, frame} -> on_payload(frame, %{state | seq: frame["s"] || state.seq})
      :error -> state
    end
  end

  defp on_frame({:ping, data}, state), do: send_raw(state, {:pong, data})
  defp on_frame({:close, code, _reason}, state), do: closed(state, {:close, code})
  defp on_frame({:error, reason}, state), do: closed(state, reason)
  defp on_frame(_frame, state), do: state

  defp on_payload(%{"op" => 10, "d" => %{"heartbeat_interval" => interval}}, state) do
    state = %{state | interval: interval, acked?: true}
    state = schedule_heartbeat(state, Protocol.first_heartbeat(interval))

    if state.session_id && state.seq do
      send_frame(state, Protocol.resume(token_of(state), state.session_id, state.seq))
    else
      send_frame(state, Protocol.identify(token_of(state), state.content?))
    end
  end

  defp on_payload(%{"op" => 11}, state), do: %{state | acked?: true}
  defp on_payload(%{"op" => 1}, state), do: send_frame(state, Protocol.heartbeat(state.seq))
  defp on_payload(%{"op" => 7}, state), do: reconnect(state, :resume)
  defp on_payload(%{"op" => 9, "d" => resumable}, state), do: reconnect(state, if(resumable == true, do: :resume, else: :reidentify))

  defp on_payload(%{"op" => 0, "t" => "READY", "d" => d}, state) do
    Logger.info("[discord:#{state.slug}] connected as #{get_in(d, ["user", "username"])}")

    %{
      state
      | session_id: d["session_id"],
        resume_url: d["resume_gateway_url"],
        bot_id: get_in(d, ["user", "id"]),
        attempt: 0
    }
  end

  defp on_payload(%{"op" => 0, "t" => "RESUMED"}, state), do: %{state | attempt: 0}

  defp on_payload(%{"op" => 0, "t" => "MESSAGE_CREATE", "d" => d}, state) do
    handle_message(state, d)
    state
  end

  defp on_payload(_frame, state), do: state

  ###
  ### a message
  ###

  # Only what somebody said, by a person, and only what could be for this bot, ever leaves this
  # process: a busy server is a firehose of messages that are nobody's business, and each one
  # that got as far as `Pepe.Webhooks` would cost a session to look at.
  defp handle_message(state, d) do
    payload = %{"t" => "MESSAGE_CREATE", "d" => d, "bot_id" => state.bot_id}

    with true <- d["type"] in @message_types,
         false <- get_in(d, ["author", "bot"]) == true or get_in(d, ["author", "id"]) == state.bot_id,
         {:ok, entry} <- fetch_entry(state.slug),
         true <- Provider.addressed?(entry, payload) or session?(entry, d) do
      Pepe.Webhooks.handle_gateway_event(state.slug, payload)
    end
  rescue
    e -> Logger.warning("[discord:#{state.slug}] could not handle a message: #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("[discord:#{state.slug}] could not handle a message: #{inspect(reason)}")
  end

  # A conversation that already exists may have waived the @mention requirement (`/mention
  # off`); that is decided by the session, so a message in it is passed on to be looked at.
  defp session?(entry, d) do
    Registry.lookup(Pepe.Agent.Registry, Pepe.Webhooks.session_key(entry, "ch:" <> to_string(d["channel_id"]))) != []
  end

  ###
  ### ending and restarting a connection
  ###

  defp closed(state, {:close, code}) do
    case Protocol.close_action(code, state.content?) do
      :stop ->
        Logger.error("[discord:#{state.slug}] #{Protocol.explain(code)}; not reconnecting")
        {:stop, state}

      :without_content ->
        Logger.warning(
          "[discord:#{state.slug}] the Message Content intent is not enabled for this app, so messages that do not " <>
            "mention the bot arrive without their text. Reconnecting without it: direct messages and @mentions work. " <>
            "Enable it on the app's Bot page in the Developer Portal to read every message."
        )

        reconnect(%{state | content?: false}, :reidentify)

      action ->
        reconnect(state, action)
    end
  end

  defp closed(state, reason) do
    Logger.info("[discord:#{state.slug}] connection ended: #{inspect(reason)}")
    reconnect(state, :resume)
  end

  # Drop the socket, forget the session if it cannot be resumed, and try again after a wait.
  defp reconnect(state, action) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.heartbeat, do: Process.cancel_timer(state.heartbeat)

    state =
      case action do
        :reidentify -> %{state | session_id: nil, seq: nil, resume_url: nil}
        _resume -> state
      end

    schedule_reconnect(%{state | conn: nil, ref: nil, websocket: nil, status: :closed, heartbeat: nil})
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, Protocol.backoff(state.attempt))
    %{state | attempt: state.attempt + 1}
  end

  defp schedule_heartbeat(state, delay) do
    if state.heartbeat, do: Process.cancel_timer(state.heartbeat)
    %{state | heartbeat: Process.send_after(self(), :heartbeat, delay)}
  end

  ###
  ### sending
  ###

  defp token_of(state) do
    case fetch_entry(state.slug) do
      {:ok, entry} -> token(entry)
      _ -> nil
    end
  end

  defp send_frame(state, frame), do: send_raw(state, {:text, Jason.encode!(frame)})

  defp send_raw(%{status: :open} = state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, _websocket_or_conn, reason} -> closed(state, {:send, reason})
    end
  end

  defp send_raw(state, _frame), do: state
end
