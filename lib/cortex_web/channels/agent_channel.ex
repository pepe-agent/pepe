defmodule CortexWeb.AgentChannel do
  @moduledoc """
  Streaming agent conversation over WebSocket.

  Topic: `agent:<agent_name>` — use `agent:default` for the default agent.

  Inbound events:
    * `"prompt"`  %{"text" => "..."}  — send a message; streams the reply
    * `"reset"`                        — clear the conversation history

  Outbound events:
    * `"delta"`        %{"text" => "..."}        — streamed text fragment
    * `"tool_call"`    %{"name", "arguments"}    — a tool is being invoked
    * `"tool_result"`  %{"name", "output"}       — tool output
    * `"done"`         %{"content" => "..."}      — final answer
    * `"watch"`        %{"text" => "..."}         — a fired watch's notification
    * `"error"`        %{"reason" => "..."}

  A watch created from this connection (via the `watch` tool) delivers back here as a
  `"watch"` event. Pass a stable `session` in the join payload to keep the same watch
  channel across reconnects; otherwise a per-connection id is used.
  """
  use CortexWeb, :channel

  alias Cortex.Agent.Runtime
  alias Cortex.ApiScope
  alias Cortex.LLM.Message
  alias Cortex.Watch.Delivery

  @impl true
  def join("agent:" <> topic, payload, socket) do
    scope = socket.assigns[:api_scope] || :unrestricted
    # "default" (or an empty topic) means "the scope's default agent"; any other name
    # is resolved and authorized against the token scope, so a client can't join an
    # agent outside what its token allows.
    requested = if topic in ["", "default"], do: nil, else: topic

    case ApiScope.authorize_agent(requested, scope) do
      nil ->
        {:error, %{reason: "agent not accessible: #{inspect(topic)}"}}

      agent ->
        key = "ws:" <> to_string(payload["session"] || System.unique_integer([:positive]))
        subscribe_watches(key)

        {:ok,
         assign(socket,
           agent: agent,
           messages: [Message.system(agent.system_prompt)],
           watch_key: key
         )}
    end
  end

  # Listen for this connection's fired watches, and register so the scheduler knows a
  # live surface is here (the Registry entry is tied to this process and cleared on
  # disconnect). The scheduler retries any held delivery on its next tick.
  defp subscribe_watches(key) do
    topic = Delivery.topic(%{"channel" => "ws", "key" => key})
    Phoenix.PubSub.subscribe(Cortex.PubSub, topic)
    Registry.register(Cortex.Watch.Subscribers, topic, nil)
  end

  @impl true
  def handle_in("reset", _payload, socket) do
    agent = socket.assigns.agent
    {:reply, :ok, assign(socket, messages: [Message.system(agent.system_prompt)])}
  end

  def handle_in("prompt", %{"text" => text}, socket) do
    agent = socket.assigns.agent
    messages = socket.assigns.messages ++ [Message.user(text)]
    channel = self()

    on_event = fn
      {:assistant_delta, t} -> push_event(channel, "delta", %{text: t})
      {:tool_call, name, args} -> push_event(channel, "tool_call", %{name: name, arguments: args})
      {:tool_result, name, out} -> push_event(channel, "tool_result", %{name: name, output: out})
      _ -> :ok
    end

    Task.start(fn ->
      opts = [stream: true, on_event: on_event, session_key: socket.assigns.watch_key]

      case Runtime.run(agent, messages, opts) do
        {:ok, content, all} ->
          push_event(channel, "done", %{content: content})
          send(channel, {:update_messages, all})

        {:error, reason} ->
          push_event(channel, "error", %{reason: inspect(reason)})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:push_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:update_messages, messages}, socket) do
    {:noreply, assign(socket, messages: messages)}
  end

  # A watch created from this connection fired — push its message to the client.
  def handle_info({:watch_message, _origin, text}, socket) do
    push(socket, "watch", %{text: text})
    {:noreply, socket}
  end

  # Events are produced from a Task; route them through the channel process so
  # `push/3` runs in the socket's transport process.
  defp push_event(channel, event, payload), do: send(channel, {:push_event, event, payload})
end
