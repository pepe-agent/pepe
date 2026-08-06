defmodule PepeWeb.RealtimeChannel do
  @moduledoc """
  Duplex audio over WebSocket, carried between a client and whichever installed
  `Pepe.Realtime.Provider` a connection asks for - see that module's moduledoc for the
  primitive this exists to provide.

  Topic: `realtime:<agent_name>` - use `realtime:default` for the default agent. The
  join payload must name a `"provider"` (a `Pepe.Realtime.Provider` plugin's own
  `name/0`); joining fails if none is installed under that name, the same way
  `PepeWeb.AgentChannel` fails a join against an agent the token can't reach.

  Inbound:
    * a **binary** push on the `"audio"` event - one inbound audio chunk, handed
      straight to the provider.
    * `"text"` %{"text" => "..."} - an inbound text message, for a provider/client that
      mixes text and audio in the same session (a caption echoed back, a typed
      interruption) rather than audio only.

  Outbound:
    * a **binary** push on `"audio"` - an outbound audio chunk from the provider.
    * `"text"` %{"text" => "..."} - an outbound transcript/caption line.
    * `"stopped"` %{"reason" => "..."} - the provider ended the session on its own.
  """
  use PepeWeb, :channel

  alias Pepe.ApiScope
  alias Pepe.Realtime

  @impl true
  def join("realtime:" <> topic, payload, socket) do
    scope = socket.assigns[:api_scope] || :unrestricted
    requested = if topic in ["", "default"], do: nil, else: topic

    with :ok <- check_chat_allowed(scope),
         {:ok, agent} <- fetch_agent(requested, scope),
         {:ok, provider} <- fetch_provider(payload["provider"]),
         {:ok, session} <- start_session(provider, agent, self()) do
      {:ok, assign(socket, agent: agent, provider: provider, session: session)}
    else
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  # Every other provider call goes through guarded/2 (below) - this one can't wait for a
  # first handle_in to get that protection, since it runs during the join itself. Without
  # it, a provider that raises here would crash the join outright (a raw channel crash
  # instead of a clean `{:error, reason}` reply) and leak whatever it allocated before
  # raising, with no session for terminate/2 to ever call stop/1 on.
  defp start_session(provider, agent, sink) do
    case provider.start(agent, [], sink) do
      {:ok, _session} = ok -> ok
      {:error, _reason} = err -> err
      other -> {:error, "malformed start/3 return: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp check_chat_allowed(scope), do: if(ApiScope.chat?(scope), do: :ok, else: {:error, "this token is not allowed to run agents"})

  defp fetch_agent(requested, scope) do
    case ApiScope.authorize_agent(requested, scope) do
      nil -> {:error, "agent not accessible: #{inspect(requested)}"}
      agent -> {:ok, agent}
    end
  end

  defp fetch_provider(name) do
    case Realtime.get(name) do
      nil -> {:error, "unknown realtime provider: #{inspect(name)}"}
      mod -> {:ok, mod}
    end
  end

  @impl true
  def handle_in("audio", {:binary, chunk}, socket) do
    %{provider: provider, session: session} = socket.assigns
    guarded(socket, fn -> provider.push_audio(session, chunk) end)
  end

  def handle_in("text", %{"text" => text}, socket) do
    %{provider: provider, session: session} = socket.assigns

    if Code.ensure_loaded?(provider) and function_exported?(provider, :push_text, 2) do
      guarded(socket, fn -> provider.push_text(session, text) end)
    else
      {:reply, {:error, %{reason: "this provider does not accept text input"}}, socket}
    end
  end

  # An unrecognized event (a malformed client, a future/renamed event this version
  # doesn't know about) - answered, not a `FunctionClauseError` that would take the
  # whole connection down over one bad push.
  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown event: #{event}"}}, socket}
  end

  # A crashing provider call must not take the whole connection down with it - one bad
  # chunk should end that chunk, not the session (see Pepe.Realtime.Provider's own
  # crash-containment expectations, the same reasoning Pepe.Slots.Guard's safe_apply/4
  # uses for every other plugin call site in this codebase).
  defp guarded(socket, fun) do
    case fun.() do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
      _other -> {:noreply, socket}
    end
  rescue
    e -> {:reply, {:error, %{reason: Exception.message(e)}}, socket}
  catch
    kind, reason -> {:reply, {:error, %{reason: "#{kind}: #{inspect(reason)}"}}, socket}
  end

  @impl true
  def handle_info({:realtime_audio, chunk}, socket) do
    push(socket, "audio", {:binary, chunk})
    {:noreply, socket}
  end

  def handle_info({:realtime_text, text}, socket) do
    push(socket, "text", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:realtime_stopped, reason}, socket) do
    push(socket, "stopped", %{reason: inspect(reason)})
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns do
      %{provider: provider, session: session} -> provider.stop(session)
      _ -> :ok
    end
  end
end
