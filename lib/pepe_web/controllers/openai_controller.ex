defmodule PepeWeb.OpenAIController do
  @moduledoc """
  OpenAI-compatible HTTP API. Lets any OpenAI client (SDKs, curl, LangChain, etc.)
  point at Pepe and talk to a local agent.

      POST /v1/chat/completions   # streaming and non-streaming
      GET  /v1/models             # lists agents and model connections

  The request `model` field selects an Pepe *agent* by name (so the agent's
  tools and system prompt apply). If no agent matches, it falls back to a raw
  model connection by name. If neither matches, the default agent is used.
  """
  use PepeWeb, :controller

  require Logger

  alias Pepe.Agent.Runtime
  alias Pepe.ApiScope
  alias Pepe.Project
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.LLM.Message

  def models(conn, _params) do
    scope = conn.assigns[:api_scope] || :unrestricted
    agents = Enum.map(ApiScope.visible_agents(scope), &model_object(&1.name, "agent"))
    # Raw model connections are only listed for open/root scope; project/agent tokens
    # see only their agents.
    models =
      if ApiScope.root_or_open?(scope),
        do: Enum.map(Config.models(), &model_object(&1.name, "model")),
        else: []

    json(conn, %{"object" => "list", "data" => agents ++ models})
  end

  defp model_object(id, owned_by) do
    %{"id" => id, "object" => "model", "created" => 0, "owned_by" => "pepe:" <> owned_by}
  end

  def chat_completions(conn, params) do
    messages = normalize_messages(params["messages"] || [])
    scope = conn.assigns[:api_scope] || :unrestricted
    {agent, model} = resolve(params["model"], scope)

    cond do
      # One gate for "may this token run an agent at all", ahead of every question about
      # *which* agent - a token minted read-only (usage only) stops here.
      not ApiScope.chat?(scope) ->
        error(conn, 403, "this token is not allowed to run agents")

      # A named agent that resolved to nothing under a real (non-open) scope is out of
      # bounds - refuse without revealing whether it exists elsewhere.
      is_nil(agent) and scope != :unrestricted and present?(params["model"]) ->
        error(conn, 403, "agent not accessible with this token")

      is_nil(agent) ->
        error(conn, 400, "no agent or model resolved for #{inspect(params["model"])}")

      true ->
        respond(conn, params, agent, model, messages)
    end
  end

  defp respond(conn, params, agent, model, messages) do
    stream? = params["stream"] == true
    session_id = session_from(params, conn)

    cond do
      # Stateful mode: a session id was provided, so the server keeps the
      # conversation. Only the latest user message is needed each call.
      is_binary(session_id) and session_id != "" ->
        session_response(conn, agent, session_id, last_user_text(messages), stream?)

      stream? ->
        stream_response(conn, agent, model, messages)

      true ->
        sync_response(conn, agent, model, messages)
    end
  end

  # Build the conversation id from the two dimensions a caller can send: the standard OpenAI `user`
  # (who) and `session_id` / `X-Session-Id` (which conversation).
  #
  # When a `session_id` is present it IS the conversation id, on its own - `user` does not enter the
  # key. This is deliberate: a client that sends `session_id` on every call but `user` only on some
  # (common when different call sites are inconsistent) would otherwise alternate between keys `s`
  # and `user:s`, splitting ONE conversation into two that each see half the history. Per-caller
  # isolation is already provided by the token's scope (the tenant boundary); `session_id` is the
  # client's own conversation handle and is expected to be unique. With no `session_id`, `user`
  # falls back as the conversation id, so a plain OpenAI SDK still keeps a conversation.
  defp session_from(params, conn) do
    user = present(params["user"])
    sess = present(params["session_id"]) || present(session_header(conn))

    cond do
      is_binary(sess) -> sess
      is_binary(user) -> user
      true -> nil
    end
  end

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp session_header(conn) do
    case get_req_header(conn, "x-session-id") do
      [v | _] -> v
      [] -> nil
    end
  end

  defp last_user_text(messages) do
    case messages |> Enum.reverse() |> Enum.find(&(&1["role"] == "user")) do
      nil -> ""
      m -> m["content"] || ""
    end
  end

  # Resolve the requested "model" into an agent (+ optional model override) within the
  # token's scope. Agent authorization is shared with the WebSocket via Pepe.ApiScope;
  # only the open/root scope may additionally pass a request through to a bare model
  # connection wrapped in an ephemeral agent.
  defp resolve(name, scope) do
    case ApiScope.authorize_agent(name, scope) do
      %Agent{} = agent ->
        {agent, nil}

      nil ->
        if present?(name) and ApiScope.root_or_open?(scope) and Config.get_model(name),
          do: {ephemeral_agent(name), Config.get_model(name)},
          else: {nil, nil}
    end
  end

  defp present?(v), do: is_binary(v) and v != ""

  defp ephemeral_agent(model_name) do
    %Pepe.Config.Agent{
      name: "_passthrough",
      model: model_name,
      system_prompt: "You are a helpful assistant.",
      tools: [],
      max_iterations: 1
    }
  end

  # The incoming messages already drive the conversation; if the caller didn't
  # send a system message, prepend the agent's persona.
  defp normalize_messages(messages) do
    Enum.map(messages, fn m ->
      %{"role" => m["role"], "content" => m["content"]}
      |> maybe_put("tool_calls", m["tool_calls"])
      |> maybe_put("tool_call_id", m["tool_call_id"])
      |> maybe_put("name", m["name"])
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # Matches what every other surface sends: the agent's own system_prompt is only the seed -
  # Pepe.Agent.Workspace.system_prompt/1 is what actually assembles persona/identity/boot files,
  # the behavior contract, docs/skills indexes and the rest of the framework scaffolding around
  # it. Using the bare seed here used to mean an OpenAI-compatible client that sent no system
  # message of its own got a noticeably thinner prompt than the same agent talking over Telegram,
  # the console, or a WebSocket session - the same agent, quietly not the same agent.
  defp prepend_system(messages, agent) do
    if Enum.any?(messages, &(&1["role"] == "system")) do
      messages
    else
      [Message.system(agent_system_prompt(agent)) | messages]
    end
  end

  # "_passthrough" isn't a real agent - it's a bare model connection wearing an ephemeral
  # struct so the rest of this controller can treat it uniformly. It has no docs, no skills,
  # no tools (`tools: [], max_iterations: 1`), so wrapping it in Workspace.system_prompt/1's
  # full framework scaffolding (behavior contract, docs/skills indexes, boot files) would hand
  # a raw-model client instructions about a framework it never opted into. Keep its bare seed.
  defp agent_system_prompt(%{name: "_passthrough"} = agent), do: agent.system_prompt
  defp agent_system_prompt(agent), do: Pepe.Agent.Workspace.system_prompt(agent)

  ###
  ### stateful sessions
  ###

  # The conversation lives in a supervised GenServer keyed per scope so a session id can't be reused
  # across projects to reach another tenant's conversation. The **agent** is part of the key too:
  # `Pepe.Agent.chat` binds an agent only when it first creates the session and never re-binds, so
  # without this, two `model:` values (two agents) sharing a `session_id` in one scope would have the
  # second request answered by the FIRST agent, with the first agent's history - a silent crossing.
  # Keying by agent gives each its own thread instead.
  defp session_key(agent, session_id) do
    "api:" <> Pepe.Config.resolve_scope(Project.of(agent.name)) <> ":" <> agent_dim(agent) <> ":" <> session_id
  end

  # The passthrough agent wrapping a bare model connection is named "_passthrough" for EVERY model,
  # so it must carry the model name to stay distinct; a real agent is identified by its handle alone
  # (and keying it by model too would fork every session the moment its model config changed).
  defp agent_dim(%{name: "_passthrough", model: model}), do: "_passthrough#" <> to_string(model)
  defp agent_dim(%{name: name}), do: name

  defp session_response(conn, agent, session_id, text, false) do
    key = session_key(agent, session_id)

    case Pepe.Agent.chat(key, agent.name, text) do
      {:ok, reply} -> json(conn, completion_object(agent.name, reply, session_id))
      {:error, reason} -> upstream_error(conn, "session error", reason)
    end
  end

  # An agent with hooks configured can't stream live deltas (Pepe.Hooks.stream?/1) - a
  # delta is always the model's raw, un-hooked text, and Pepe.Agent.chat/4 only applies
  # :outbound redaction/mutation once the full reply is in hand, after the turn returns.
  # The client asked for stream: true and still gets a valid SSE response either way -
  # with hooks, as one "content" chunk carrying the whole already-hooked reply instead of
  # many incremental ones.
  defp session_response(conn, agent, session_id, text, true) do
    key = session_key(agent, session_id)
    id = "chatcmpl-" <> random_id()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    conn =
      if Pepe.Hooks.stream?(agent) do
        stream_session_deltas(conn, key, agent, text, id)
      else
        emit_buffered_sse(conn, id, agent.name, Pepe.Agent.chat(key, agent.name, text))
      end

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp stream_session_deltas(conn, key, agent, text, id) do
    parent = self()

    on_event = fn
      {:assistant_delta, text} -> send(parent, {:delta, text})
      {:done, _content} -> send(parent, :done)
      {:error, reason} -> send(parent, {:stream_error, reason})
      _ -> :ok
    end

    task =
      Task.async(fn ->
        Pepe.Agent.chat(key, agent.name, text, stream: true, on_event: on_event)
      end)

    conn = stream_loop(conn, id, agent.name)
    # The stream loop already bounds itself (its `after 180_000`). Wait for the task with a finite
    # ceiling and kill it if it overruns, so a hung provider never leaves the request process and
    # its connection pinned forever (a slow resource-exhaustion vector under load).
    Task.shutdown(task, 5_000)
    conn
  end

  ###
  ### non-streaming
  ###

  defp sync_response(conn, agent, model, messages) do
    messages = prepend_system(messages, agent)
    opts = if model, do: [model: model], else: []

    case run_with_hooks(agent, messages, opts) do
      {:ok, content, _all} ->
        json(conn, completion_object(agent.name, content))

      {:error, reason} ->
        upstream_error(conn, "agent error", reason)
    end
  end

  # Every /v1 call not backed by a Pepe.Agent.Session (stateless: no session_id was sent,
  # so sync_response/stream_response call Runtime.run/3 directly) used to skip Pepe.Hooks
  # entirely, streaming or not - a real agent (not just the "_passthrough" bare-model
  # wrapper) reached over this API with `hooks` configured got neither the built-in
  # PII/LLM/HTTP/Presidio redaction nor a plugin content-mutation hook, on a public HTTP
  # surface. `:inbound` only sees the LATEST user message - a stateless client resends its
  # own history on every call, and there is no server-side memory of an earlier turn to
  # retroactively redact once it has already left.
  defp run_with_hooks(agent, messages, opts) do
    text = last_user_text(messages)
    {redacted, entries} = Pepe.Hooks.transform(:inbound, text, agent, %{"map" => []})
    messages = messages |> replace_last_user_text(redacted) |> inject_time_reminder()
    Pepe.Hooks.start_map(entries)

    case Runtime.run(agent, messages, opts) do
      {:ok, reply, all} ->
        map = Pepe.Hooks.take_map()
        {shown, _} = Pepe.Hooks.transform(:outbound, reply, agent, %{"map" => map})
        {:ok, Pepe.Hooks.restore(shown, map), all}

      other ->
        Pepe.Hooks.take_map()
        other
    end
  end

  defp replace_last_user_text(messages, text) do
    case last_user_index(messages) do
      nil -> messages
      idx -> List.update_at(messages, idx, &Map.put(&1, "content", text))
    end
  end

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {m, _i} -> m["role"] == "user" end)
    |> List.last()
    |> case do
      nil -> nil
      {_m, i} -> i
    end
  end

  # The stateless path replays whatever history the client sent, every request - the
  # current time can't live in the (cache-stable) system prompt, so it rides along as an
  # ephemeral note right before the newest user turn, same as a session turn gets (see
  # Pepe.Agent.Workspace.time_reminder/0). Inserted before, not appended after, the last
  # user message so nothing downstream that looks for "the last user message" finds the
  # reminder instead.
  defp inject_time_reminder(messages) do
    case last_user_index(messages) do
      nil ->
        messages

      idx ->
        {before_user, from_user} = Enum.split(messages, idx)
        before_user ++ Pepe.Agent.Workspace.time_reminder() ++ from_user
    end
  end

  # Emits a still-valid SSE response for a run that didn't (or couldn't) stream deltas:
  # one "content" chunk with the whole reply, then the usual finish chunk. Accepts either
  # `run_with_hooks/3`'s 3-tuple or `Pepe.Agent.chat/4`'s 2-tuple success shape.
  defp emit_buffered_sse(conn, id, model_name, {:ok, content, _all}),
    do: emit_buffered_sse(conn, id, model_name, {:ok, content})

  defp emit_buffered_sse(conn, id, model_name, {:ok, content}) do
    content_payload = chunk_object(id, model_name, %{"content" => content})
    {:ok, conn} = chunk(conn, "data: #{Jason.encode!(content_payload)}\n\n")
    finish_payload = chunk_object(id, model_name, %{}, "stop")
    {:ok, conn} = chunk(conn, "data: #{Jason.encode!(finish_payload)}\n\n")
    conn
  end

  defp emit_buffered_sse(conn, id, model_name, {:error, reason}) do
    Logger.error("[/v1] stream error: #{inspect(reason)}")
    payload = chunk_object(id, model_name, %{"content" => "\n[error: upstream request failed]"}, "stop")
    {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
    conn
  end

  # Never serialize the raw `reason` into the response: it can carry the provider's base_url,
  # internal hostnames, and upstream error internals, handed to any caller (including another
  # tenant's token or the public widget). Log it server-side, return a generic message.
  defp upstream_error(conn, label, reason) do
    Logger.error("[/v1] #{label}: #{inspect(reason)}")
    error(conn, 502, label)
  end

  defp completion_object(model_name, content, session_id \\ nil) do
    %{
      "id" => "chatcmpl-" <> random_id(),
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model_name,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ]
    }
    |> then(fn obj -> if session_id, do: Map.put(obj, "session_id", session_id), else: obj end)
  end

  ###
  ### streaming (SSE)
  ###

  defp stream_response(conn, agent, model, messages) do
    messages = prepend_system(messages, agent)
    id = "chatcmpl-" <> random_id()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    opts = if(model, do: [model: model], else: [])

    conn =
      if Pepe.Hooks.stream?(agent) do
        stream_message_deltas(conn, agent, messages, id, opts)
      else
        emit_buffered_sse(conn, id, agent.name, run_with_hooks(agent, messages, opts))
      end

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp stream_message_deltas(conn, agent, messages, id, opts) do
    parent = self()

    on_event = fn
      {:assistant_delta, text} -> send(parent, {:delta, text})
      {:done, _content} -> send(parent, :done)
      {:error, reason} -> send(parent, {:stream_error, reason})
      _ -> :ok
    end

    run_opts = [stream: true, on_event: on_event] ++ opts
    task = Task.async(fn -> run_with_hooks(agent, messages, run_opts) end)

    conn = stream_loop(conn, id, agent.name)
    # The stream loop already bounds itself (its `after 180_000`). Wait for the task with a finite
    # ceiling and kill it if it overruns, so a hung provider never leaves the request process and
    # its connection pinned forever (a slow resource-exhaustion vector under load).
    Task.shutdown(task, 5_000)
    conn
  end

  defp stream_loop(conn, id, model_name) do
    receive do
      {:delta, text} ->
        payload = chunk_object(id, model_name, %{"content" => text})
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
        stream_loop(conn, id, model_name)

      :done ->
        payload = chunk_object(id, model_name, %{}, "stop")
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
        conn

      {:stream_error, reason} ->
        Logger.error("[/v1] stream error: #{inspect(reason)}")
        payload = chunk_object(id, model_name, %{"content" => "\n[error: upstream request failed]"}, "stop")
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(payload)}\n\n")
        conn
    after
      180_000 -> conn
    end
  end

  defp chunk_object(id, model_name, delta, finish_reason \\ nil) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => model_name,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}]
    }
  end

  ###
  ### helpers
  ###

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => %{"message" => message, "type" => "pepe_error"}})
  end

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
