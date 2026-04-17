defmodule PepeWeb.AgentChannel do
  @moduledoc """
  Streaming agent conversation over WebSocket.

  Topic: `agent:<agent_name>` - use `agent:default` for the default agent.

  The join reply carries `%{history: [%{role:, content:}, ...]}` - the session's
  prior turns (system/tool messages stripped), if any, so a client can rehydrate its
  view of an already-live session instead of starting blank.

  Inbound events:
    * `"prompt"`  %{"text" => "..."}  - send a message; streams the reply
    * `"reset"`                        - clear the conversation history

  Outbound events:
    * `"delta"`         %{"text" => "..."}        - streamed text fragment
    * `"tool_call"`     %{"name", "arguments"}    - a tool is being invoked
    * `"tool_result"`   %{"name", "output"}       - tool output
    * `"done"`          %{"content" => "..."}      - final answer
    * `"session_ended"` %{}                        - the agent called `end_session`;
      its reply (already delivered via the preceding `"done"`) was the last one on
      the old context, the NEXT prompt starts fresh. Sent as an explicit event (not
      left for the client to infer from a `tool_result`'s `name`) so a client doesn't
      need to know anything about tool internals to show that the conversation ended.
    * `"watch"`         %{"text" => "..."}         - a fired watch's notification
    * `"error"`         %{"reason" => "..."}

  A watch created from this connection (via the `watch` tool) delivers back here as a
  `"watch"` event. Pass a stable `session` in the join payload to keep the same watch
  channel across reconnects; otherwise a per-connection id is used.
  """
  use PepeWeb, :channel

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.ApiScope
  alias Pepe.Watch.Delivery

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
        key = session_key(scope, payload)
        subscribe_watches(key)
        # Routed through Pepe.Agent.Session (not Runtime.run directly), same as every
        # other channel: shows up in the dashboard's live session list, picks up the
        # agent's full system prompt (SOUL.md/BOOT.md/docs index, not just the bare
        # config prompt), and gets restart-recovery for free. A "widget:" key is
        # ephemeral + TTL'd by default (Pepe.Agent.Session.default_ephemeral?/1) - an
        # anonymous visitor's chat isn't meant to accumulate on disk forever, and
        # there's no "trainers" concept here yet, so it never feeds memory
        # (`learn: false` at the call site in `run_prompt/2`). Not passed explicitly
        # here: the policy needs to hold even when some OTHER caller (e.g. the
        # dashboard's own session viewer) reaches `ensure/3` for this key first.
        {:ok, _pid} = SessionSupervisor.ensure(key, agent.name)

        # The join reply carries prior history (if any) so a client can rehydrate its
        # view of an already-live session (e.g. after a page reload, which drops the
        # client's own in-memory transcript but not the server-side one) instead of
        # looking like the conversation was lost.
        socket = assign(socket, agent: agent, watch_key: key, lang: blank_to_nil(payload["lang"]))
        {:ok, %{history: visible_history(key)}, socket}
    end
  end

  defp visible_history(key) do
    key
    |> Session.history()
    |> Enum.reject(&(&1["role"] in ["system", "tool"]))
    |> Enum.map(&%{role: &1["role"], content: to_string(&1["content"] || "")})
    |> Enum.reject(&(&1.content == "" and &1.role == "assistant"))
  end

  # A widget token's origin becomes part of the key ("widget:example.com:<id>"), so
  # someone running more than one widget (several sites) can tell their conversations
  # apart in the dashboard's session list instead of everything piling into one
  # generic "Web" group indistinguishable from the dashboard's own built-in chat.
  # Anything else (a same-host tool, a plain non-widget token) keeps the existing
  # "web:" prefix.
  defp session_key(%{kind: "widget", allowed_origin: origin}, payload) do
    "widget:" <> site(origin) <> ":" <> to_string(payload["session"] || System.unique_integer([:positive]))
  end

  defp session_key(_scope, payload) do
    "web:" <> to_string(payload["session"] || System.unique_integer([:positive]))
  end

  defp site(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> host <> port_suffix(URI.parse(origin))
      _ -> "unknown-site"
    end
  end

  defp site(_origin), do: "unknown-site"

  defp port_suffix(%URI{port: nil}), do: ""
  defp port_suffix(%URI{scheme: "https", port: 443}), do: ""
  defp port_suffix(%URI{scheme: "http", port: 80}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_v), do: nil

  # Listen for this connection's fired watches, and register so the scheduler knows a
  # live surface is here (the Registry entry is tied to this process and cleared on
  # disconnect). The scheduler retries any held delivery on its next tick.
  defp subscribe_watches(key) do
    topic = Delivery.topic(%{"channel" => "ws", "key" => key})
    Phoenix.PubSub.subscribe(Pepe.PubSub, topic)
    Registry.register(Pepe.Watch.Subscribers, topic, nil)
  end

  @impl true
  def handle_in("reset", _payload, socket) do
    Session.reset(socket.assigns.watch_key)
    {:reply, :ok, socket}
  end

  def handle_in("prompt", %{"text" => text}, socket) do
    case widget_rate_limit(socket) do
      :ok ->
        run_prompt(socket, text)

      {:error, retry_ms} ->
        # A channel reply (`{:reply, {:error, ...}, socket}`) is the "proper" Phoenix
        # way to answer a push, but the widget's minimal client (no `phoenix` package)
        # never inspects a `phx_reply`'s status - only whether it is "ok" - so an error
        # reply there would be silently swallowed. Use the same "error" event the rest
        # of a run's failures already push, which the widget does render.
        push(socket, "error", %{reason: rate_limit_message(retry_ms)})
        {:noreply, socket}
    end
  end

  # A widget-scoped connection's token sits in public page source, so its prompts
  # are rate-limited; every other scope (a plain API token, a same-host tool) is
  # unaffected. Keyed by this connection's own session, so one visitor can't exhaust
  # another's budget.
  defp widget_rate_limit(socket) do
    case socket.assigns[:api_scope] do
      %{kind: "widget"} -> PepeWeb.WidgetThrottle.check(socket.assigns.watch_key)
      _ -> :ok
    end
  end

  defp rate_limit_message(retry_ms), do: "rate limited, try again in #{Integer.floor_div(retry_ms, 1000)}s"

  defp run_prompt(socket, text) do
    key = socket.assigns.watch_key
    channel = self()

    on_event = fn
      {:assistant_delta, t} -> push_event(channel, "delta", %{text: t})
      {:tool_call, name, args} -> push_event(channel, "tool_call", %{name: name, arguments: args})
      {:tool_result, name, out} -> push_event(channel, "tool_result", %{name: name, output: out})
      _ -> :ok
    end

    Task.start(fn ->
      # No human on the other end of a public/anonymous connection to approve a risky
      # tool call - `authorize: nil` runs freely, exactly like a WhatsApp `support`
      # connection; the mitigation is binding the widget's token to a narrow, safe
      # agent (see the widget docs). `learn: false` until there's a real "who counts
      # as a trainer" concept for an anonymous visitor. `lang` (the site's declared
      # language, from the join payload) nudges the agent's first reply - see
      # Session's own first-turn-only guard.
      opts = [stream: true, on_event: on_event, authorize: nil, learn: false, lang: socket.assigns[:lang]]

      case Session.chat(key, text, opts) do
        {:ok, content} ->
          push_event(channel, "done", %{content: content})

        {:error, :busy} ->
          push_event(channel, "error", %{reason: "already answering, please wait"})

        {:error, reason} ->
          push_event(channel, "error", %{reason: inspect(reason)})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:push_event, "tool_result", %{name: "end_session"} = payload}, socket) do
    push(socket, "tool_result", payload)
    push(socket, "session_ended", %{})
    {:noreply, socket}
  end

  def handle_info({:push_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # A watch created from this connection fired - push its message to the client.
  def handle_info({:watch_message, _origin, text}, socket) do
    push(socket, "watch", %{text: text})
    {:noreply, socket}
  end

  # Events are produced from a Task; route them through the channel process so
  # `push/3` runs in the socket's transport process.
  defp push_event(channel, event, payload), do: send(channel, {:push_event, event, payload})
end
