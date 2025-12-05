defmodule CortexWeb.OpenAIController do
  @moduledoc """
  OpenAI-compatible HTTP API. Lets any OpenAI client (SDKs, curl, LangChain, etc.)
  point at Cortex and talk to a local agent.

      POST /v1/chat/completions   # streaming and non-streaming
      GET  /v1/models             # lists agents and model connections

  The request `model` field selects an Cortex *agent* by name (so the agent's
  tools and system prompt apply). If no agent matches, it falls back to a raw
  model connection by name. If neither matches, the default agent is used.
  """
  use CortexWeb, :controller

  alias Cortex.Agent.Runtime
  alias Cortex.Config
  alias Cortex.LLM.Message

  def models(conn, _params) do
    agents = Enum.map(Config.agents(), &model_object(&1.name, "agent"))
    models = Enum.map(Config.models(), &model_object(&1.name, "model"))
    json(conn, %{"object" => "list", "data" => agents ++ models})
  end

  defp model_object(id, owned_by) do
    %{"id" => id, "object" => "model", "created" => 0, "owned_by" => "cortex:" <> owned_by}
  end

  def chat_completions(conn, params) do
    messages = normalize_messages(params["messages"] || [])
    stream? = params["stream"] == true
    {agent, model} = resolve(params["model"])
    session_id = params["session_id"] || params["user"] || session_header(conn)

    cond do
      is_nil(agent) ->
        error(conn, 400, "no agent or model resolved for #{inspect(params["model"])}")

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

  # Resolve the requested "model" into an agent (+ optional model override).
  defp resolve(name) do
    cond do
      name && Config.get_agent(name) ->
        {Config.get_agent(name), nil}

      name && Config.get_model(name) ->
        # Wrap a bare model connection in an ephemeral tool-less agent.
        {ephemeral_agent(name), Config.get_model(name)}

      true ->
        {Config.default_agent(), nil}
    end
  end

  defp ephemeral_agent(model_name) do
    %Cortex.Config.Agent{
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

  defp prepend_system(messages, agent) do
    if Enum.any?(messages, &(&1["role"] == "system")) do
      messages
    else
      [Message.system(agent.system_prompt) | messages]
    end
  end

  ###
  ### stateful sessions
  ###

  # The conversation lives in a supervised GenServer keyed by "api:<session_id>".
  # Subsequent calls with the same id keep the full history server-side.
  defp session_response(conn, agent, session_id, text, false) do
    key = "api:" <> session_id

    case Cortex.Agent.chat(key, agent.name, text) do
      {:ok, reply} -> json(conn, completion_object(agent.name, reply, session_id))
      {:error, reason} -> error(conn, 502, "session error: #{inspect(reason)}")
    end
  end

  defp session_response(conn, agent, session_id, text, true) do
    key = "api:" <> session_id
    id = "chatcmpl-" <> random_id()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    parent = self()

    on_event = fn
      {:assistant_delta, text} -> send(parent, {:delta, text})
      {:done, _content} -> send(parent, :done)
      {:error, reason} -> send(parent, {:stream_error, reason})
      _ -> :ok
    end

    task =
      Task.async(fn ->
        Cortex.Agent.chat(key, agent.name, text, stream: true, on_event: on_event)
      end)

    conn = stream_loop(conn, id, agent.name)
    Task.await(task, :infinity)

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  ###
  ### non-streaming
  ###

  defp sync_response(conn, agent, model, messages) do
    messages = prepend_system(messages, agent)
    opts = if model, do: [model: model], else: []

    case Runtime.run(agent, messages, opts) do
      {:ok, content, _all} ->
        json(conn, completion_object(agent.name, content))

      {:error, reason} ->
        error(conn, 502, "agent error: #{inspect(reason)}")
    end
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

    parent = self()

    on_event = fn
      {:assistant_delta, text} -> send(parent, {:delta, text})
      {:done, _content} -> send(parent, :done)
      {:error, reason} -> send(parent, {:stream_error, reason})
      _ -> :ok
    end

    opts = [stream: true, on_event: on_event] ++ if(model, do: [model: model], else: [])

    task = Task.async(fn -> Runtime.run(agent, messages, opts) end)

    conn = stream_loop(conn, id, agent.name)
    Task.await(task, :infinity)

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
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
        payload =
          chunk_object(id, model_name, %{"content" => "\n[error: #{inspect(reason)}]"}, "stop")

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
    |> json(%{"error" => %{"message" => message, "type" => "cortex_error"}})
  end

  defp random_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
