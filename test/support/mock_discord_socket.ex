defmodule Pepe.Test.MockDiscordSocket do
  @moduledoc """
  The gateway side of `Pepe.Test.MockDiscord`: says hello, answers `IDENTIFY` with `READY`
  and `RESUME` with `RESUMED`, acknowledges heartbeats, and tells the test about each of them.

  The test drives it by sending the socket process (announced as `{:gateway_connected, pid}`)
  `{:push, frame}` to put a frame on the wire, or `{:close, code}` to end the connection with
  that close code.
  """
  @behaviour WebSock

  @bot_id "900"

  def bot_id, do: @bot_id

  @impl true
  def init(opts) do
    send(opts.test, {:gateway_connected, self()})
    hello = %{"op" => 10, "d" => %{"heartbeat_interval" => opts.interval}}
    {:push, {:text, Jason.encode!(hello)}, %{opts: opts, seq: 0}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, %{opts: opts} = state) do
    case Jason.decode!(text) do
      %{"op" => 2, "d" => d} ->
        send(opts.test, {:identify, d})
        ready = %{"user" => %{"id" => @bot_id, "username" => "pepe"}, "session_id" => "sess-1", "resume_gateway_url" => resume_url(opts)}
        dispatch("READY", ready, state)

      %{"op" => 6, "d" => d} ->
        send(opts.test, {:resume, d})
        dispatch("RESUMED", %{}, state)

      %{"op" => 1, "d" => seq} ->
        send(opts.test, {:heartbeat, seq})
        if opts.ack?, do: {:push, {:text, ~s({"op":11})}, state}, else: {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:push, frame}, state), do: {:push, {:text, Jason.encode!(frame)}, state}
  def handle_info({:dispatch, name, d}, state), do: dispatch(name, d, state)
  def handle_info({:close, code}, state), do: {:stop, :normal, {code, ""}, state}
  def handle_info(_message, state), do: {:ok, state}

  defp dispatch(name, d, state) do
    seq = state.seq + 1
    frame = %{"op" => 0, "t" => name, "s" => seq, "d" => d}
    {:push, {:text, Jason.encode!(frame)}, %{state | seq: seq}}
  end

  # Where a resumed session should connect: the same server, found through the REST answer's
  # own address so nothing here needs to know the port.
  defp resume_url(opts), do: Map.get(opts, :resume_url)
end
