defmodule Pepe.Realtime.Provider do
  @moduledoc """
  A plugin's own realtime, duplex audio backend - the primitive none of Pepe's other
  extension points can carry: a tool call, a webhook, a slot occupant are all
  request/response or one-shot, and none holds a continuous, bidirectional stream. A
  provider owns everything about how inbound audio becomes an outbound reply (a hosted
  realtime multimodal model, a streaming-STT-then-TTS pipeline, whatever the plugin
  wants); `PepeWeb.RealtimeChannel` only carries bytes between a WebSocket client and
  whichever provider a connection asked for.

  Additive, like a tool or `Pepe.Webhooks.Provider` (see their moduledocs), never a
  `Pepe.Slots` occupant: several realtime providers can be installed at once, and a
  client picks one by name per connection (the `"provider"` join payload key) - there's
  no single exclusive "the" realtime backend the way there's one memory/web_search
  occupant.

  `start/3` is called from the channel's own process, so `push_audio/2` and the
  `sink` messages below stay on that one connection's timeline without Pepe needing to
  isolate or pool anything itself - a provider that talks to a remote service manages its
  own connection/process for that (a `Task`, a `GenServer`, whatever it needs), the same
  way a webhook provider owns its own HTTP client.
  """

  alias Pepe.Config.Agent

  @callback name() :: String.t()

  @doc """
  Start a realtime session for `agent`. `sink` is a pid to send outbound events to for
  as long as the session lives:

    * `{:realtime_audio, chunk}` - an outbound audio chunk (raw bytes; encoding is
      whatever the provider and client agreed on out of band - Pepe never inspects it).
    * `{:realtime_text, text}` - an outbound transcript/caption line.
    * `{:realtime_stopped, reason}` - the provider ended the session on its own (its
      upstream disconnected, a hosted call ended) - not something the channel asked for.

  Returns an opaque `session` term threaded back through `push_audio/2`/`stop/1`.
  """
  @callback start(agent :: Agent.t(), opts :: keyword(), sink :: pid()) :: {:ok, session :: term()} | {:error, term()}

  @doc "Feed one inbound audio chunk into a running session."
  @callback push_audio(session :: term(), chunk :: binary()) :: :ok | {:error, term()}

  @doc """
  Optional: feed inbound text into a running session, for a provider/client that mixes
  text and audio in the same session (a typed interruption, a caption echoed back)
  rather than audio only. A provider that doesn't implement this simply never receives
  the channel's `"text"` event; `PepeWeb.RealtimeChannel` answers it with an error
  instead of raising an `UndefinedFunctionError`.
  """
  @callback push_text(session :: term(), text :: String.t()) :: :ok | {:error, term()}

  @doc """
  End a session and release whatever it holds (an upstream connection, a port). Must be
  safe to call more than once on the same `session` (a channel process that already
  disconnected and later crashes for an unrelated reason may end up calling this twice) -
  idempotent, not "only ever called exactly once".

  `PepeWeb.RealtimeChannel`'s own `terminate/2` calls this on a clean disconnect or a
  crash inside its own callbacks, but a channel process that's killed outright (not
  trapping exits, same as any other `GenServer`) skips `terminate/2` entirely - a
  provider holding a real upstream resource should not rely on `stop/1` as its only
  cleanup path. Monitoring `sink` (the pid passed to `start/3`) and releasing the
  resource when it goes `:DOWN` is the reliable way to catch that case too.
  """
  @callback stop(session :: term()) :: :ok

  @optional_callbacks push_text: 2
end
