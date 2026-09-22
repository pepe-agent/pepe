defmodule Pepe.Gateways.Discord.Protocol do
  @moduledoc """
  The parts of Discord's gateway protocol that are decisions rather than plumbing: what to
  send, and what a close code means for the connection that just ended. Pure, so the rules
  that decide whether a bot reconnects forever, resumes, starts over, or stops with an
  explanation can be tested without a socket.

  The gateway is a WebSocket carrying JSON frames `%{"op", "d", "s", "t"}`: the server
  says hello with a heartbeat interval, the client identifies (or resumes a session it
  lost), heartbeats until the connection ends, and receives events as `op: 0` dispatches.
  See <https://discord.com/developers/docs/events/gateway>.
  """

  import Bitwise

  @op_dispatch 0
  @op_heartbeat 1
  @op_identify 2
  @op_resume 6
  @op_reconnect 7
  @op_invalid_session 9
  @op_hello 10
  @op_heartbeat_ack 11

  # Guild messages, direct messages, and the privileged intent that lets the bot read what
  # was written in a channel it was not mentioned in. Discord withholds `content` (and
  # nothing else) without it for guild messages that do not mention the bot.
  @guild_messages 1 <<< 9
  @direct_messages 1 <<< 12
  @message_content 1 <<< 15

  @doc "Opcode names, for pattern matching on a decoded frame."
  def op(:dispatch), do: @op_dispatch
  def op(:heartbeat), do: @op_heartbeat
  def op(:identify), do: @op_identify
  def op(:resume), do: @op_resume
  def op(:reconnect), do: @op_reconnect
  def op(:invalid_session), do: @op_invalid_session
  def op(:hello), do: @op_hello
  def op(:heartbeat_ack), do: @op_heartbeat_ack

  @doc """
  The intents to ask for. `content?` is the privileged Message Content intent: it has to be
  switched on in the app's page in the Developer Portal, and asking for it without that gets
  the connection closed (4014), which `close_action/2` turns into a retry without it.
  """
  @spec intents(boolean()) :: non_neg_integer()
  def intents(content?), do: @guild_messages ||| @direct_messages ||| if(content?, do: @message_content, else: 0)

  @doc "The frame that opens a new session."
  @spec identify(String.t(), boolean()) :: map()
  def identify(token, content?) do
    %{
      "op" => @op_identify,
      "d" => %{
        "token" => token,
        "intents" => intents(content?),
        "properties" => %{"os" => "elixir", "browser" => "pepe", "device" => "pepe"}
      }
    }
  end

  @doc "The frame that picks a lost session back up, replaying what was missed."
  @spec resume(String.t(), String.t(), integer()) :: map()
  def resume(token, session_id, seq),
    do: %{"op" => @op_resume, "d" => %{"token" => token, "session_id" => session_id, "seq" => seq}}

  @doc "The keep-alive frame; `seq` is the last sequence number seen (`nil` before any)."
  @spec heartbeat(integer() | nil) :: map()
  def heartbeat(seq), do: %{"op" => @op_heartbeat, "d" => seq}

  @doc """
  What to do after the connection ended with close code `code`.

    * `:stop` - the bot cannot work as configured (bad token, an invalid intent, a version
      Discord no longer serves): reconnecting would repeat the same refusal forever.
    * `:without_content` - the privileged Message Content intent was asked for and is not
      enabled: try again without it, so DMs and mentions still work.
    * `:reidentify` - the session is gone (the sequence was invalid, or it timed out): start a
      new one, do not resume.
    * `:resume` - anything else, including a normal close: reconnect and pick the session up.
  """
  @spec close_action(integer() | nil, boolean()) :: :stop | :without_content | :reidentify | :resume
  def close_action(code, _content?) when code in [4004, 4010, 4011, 4012, 4013], do: :stop
  def close_action(4014, true), do: :without_content
  def close_action(4014, false), do: :stop
  def close_action(code, _content?) when code in [4007, 4009], do: :reidentify
  def close_action(_code, _content?), do: :resume

  @doc "Why the connection cannot continue, for the log, for the codes that stop it."
  @spec explain(integer()) :: String.t()
  def explain(4004), do: "Discord rejected the bot token (4004): check the connection's bot token"
  def explain(4010), do: "Discord rejected the shard (4010)"
  def explain(4011), do: "this bot needs sharding (4011), which Pepe does not do"
  def explain(4012), do: "Discord no longer serves this gateway version (4012)"
  def explain(4013), do: "Discord rejected the intents (4013)"

  def explain(4014),
    do: "the bot may not use the intents it asked for (4014): enable them on the app's Bot page in the Developer Portal"

  def explain(code), do: "closed with code #{code}"

  @doc "How long to wait before reconnect attempt number `attempt` (0-based): 1s, doubling, at most 60s, with jitter."
  @spec backoff(non_neg_integer()) :: pos_integer()
  def backoff(attempt) do
    # `:discord_reconnect_base_ms` exists for a test that wants to see a reconnect without
    # waiting a second for it; nothing else sets it.
    first = Application.get_env(:pepe, :discord_reconnect_base_ms, 1_000)
    base = min(first <<< min(attempt, 6), 60_000)
    base + :rand.uniform(max(div(base, 4), 1))
  end

  @doc """
  When to send the first heartbeat: a random fraction of the interval, as the protocol asks,
  so every bot that reconnects at once does not heartbeat at once.
  """
  @spec first_heartbeat(pos_integer()) :: non_neg_integer()
  def first_heartbeat(interval), do: trunc(interval * :rand.uniform())

  @doc "Decode one text frame, or `:error`."
  @spec decode(binary()) :: {:ok, map()} | :error
  def decode(text) do
    case Jason.decode(text) do
      {:ok, %{"op" => _} = frame} -> {:ok, frame}
      _ -> :error
    end
  end
end
