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
    * `"error"`        %{"reason" => "..."}
  """
  use CortexWeb, :channel

  alias Cortex.Agent.Runtime
  alias Cortex.Config
  alias Cortex.LLM.Message

  @impl true
  def join("agent:" <> agent_name, _payload, socket) do
    agent_name =
      if agent_name in ["", "default"], do: Config.default_agent_name(), else: agent_name

    case agent_name && Config.get_agent(agent_name) do
      nil ->
        {:error, %{reason: "unknown agent: #{inspect(agent_name)}"}}

      agent ->
        {:ok, assign(socket, agent: agent, messages: [Message.system(agent.system_prompt)])}
    end
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
      case Runtime.run(agent, messages, stream: true, on_event: on_event) do
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

  # Events are produced from a Task; route them through the channel process so
  # `push/3` runs in the socket's transport process.
  defp push_event(channel, event, payload), do: send(channel, {:push_event, event, payload})
end
