defmodule Pepe.LLM.Messages do
  @moduledoc """
  Adapter for the Anthropic **Messages API** (`POST {base}/messages`), used both by a
  Claude Pro/Max **subscription** (OAuth bearer) and by a plain Anthropic API key. The
  Messages API is not OpenAI-compatible, so this module translates on both ends:

    * inbound  - Pepe's OpenAI chat-format `messages`/`tools` -> Anthropic `system` +
      `messages` (with `tool_use` / `tool_result` content blocks) + `input_schema` tools.
    * outbound - the SSE `content_block_*` / `message_*` event stream -> the same
      `%{content, tool_calls, finish_reason, usage}` result `Pepe.LLM` returns, with
      `tool_calls` in Chat-Completions shape so the runtime is unchanged.

  Auth: with OAuth the access token is the bearer and the `anthropic-beta: oauth-...`
  header is sent; the subscription only authorizes requests whose first system block
  identifies the Claude Code client, so that block is prepended. With an API key the
  `x-api-key` header is used and no client block is added. Dispatched from `Pepe.LLM`
  when `model.api == "anthropic-messages"`.
  """

  alias Pepe.Config.Model

  @version "2023-06-01"
  @oauth_beta "oauth-2025-04-20"
  @client_id "You are Claude Code, Anthropic's official CLI for Claude."
  @default_max_tokens 4096

  @doc "Non-streaming: collect the stream and return the assembled result."
  def chat(%Model{} = model, messages, opts \\ []) do
    stream_chat(model, messages, fn _ -> :ok end, opts)
  end

  @doc "Streaming Messages call. `on_delta` receives each assistant text fragment."
  def stream_chat(%Model{} = model, messages, on_delta, opts \\ [])
      when is_function(on_delta, 1) do
    model = Pepe.OAuth.ensure_fresh(model)
    body = build_body(model, messages, opts)
    init = %{buffer: "", content: "", blocks: %{}, order: [], finish: nil, in: 0, out: 0, cached: 0, raw: ""}

    collector = fn {:data, data}, {req, resp} ->
      state = resp.private[:pepe] || init
      # Keep raw bytes: a non-2xx error body is streamed here, not into `resp.body`.
      state = %{state | raw: state.raw <> data}
      state = consume(state.buffer <> data, %{state | buffer: ""}, on_delta)
      {:cont, {req, %{resp | private: Map.put(resp.private, :pepe, state)}}}
    end

    req =
      Req.new(
        url: messages_url(model),
        headers: headers(model),
        json: body,
        receive_timeout: opts[:receive_timeout] || 120_000,
        # Retry transient failures, notably a stale pooled connection the server
        # already closed (`%Req.TransportError{reason: :closed}` on the first call).
        retry: :transient,
        into: collector
      )

    case Req.post(req) do
      {:ok, %{status: status, private: %{pepe: state}}} when status in 200..299 ->
        {:ok, finalize(flush(state, on_delta))}

      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, finalize(resp.private[:pepe] || init)}

      {:ok, %{status: status, private: %{pepe: %{raw: raw}}}} ->
        {:error, {:http_error, status, raw}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List the Claude model ids via `GET {base}/models`. Returns `{:ok, ids}`."
  def list_models(%Model{} = model) do
    model = Pepe.OAuth.ensure_fresh(model)
    headers = Map.put(headers(model), "accept", "application/json")

    case Req.get(models_url(model), headers: headers, receive_timeout: 30_000, retry: :transient) do
      {:ok, %{status: status, body: %{"data" => rows}}} when status in 200..299 and is_list(rows) ->
        {:ok, rows |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ###
  ### URL + headers
  ###

  defp base(%Model{base_url: base}), do: String.trim_trailing(base, "/")
  defp messages_url(model), do: base(model) <> "/messages"
  defp models_url(model), do: base(model) <> "/models"

  defp headers(%Model{} = model) do
    token = Model.resolved_api_key(model) || ""

    auth =
      if oauth?(model) do
        %{"authorization" => "Bearer " <> token, "anthropic-beta" => @oauth_beta}
      else
        %{"x-api-key" => token}
      end

    %{
      "anthropic-version" => @version,
      "content-type" => "application/json",
      "accept" => "text/event-stream"
    }
    |> Map.merge(auth)
    |> Map.merge(Model.resolved_headers(model))
  end

  defp oauth?(%Model{oauth: oauth}), do: is_map(oauth)

  ###
  ### request body
  ###

  defp build_body(%Model{} = model, messages, opts) do
    tools = to_tools(opts[:tools])

    base = %{
      "model" => model.model,
      # `opts[:max_tokens]` first so the runtime's output-cap retry (which lowers the reservation
      # after a provider rejects an over-large one) actually reaches the request.
      "max_tokens" => opts[:max_tokens] || model.max_tokens || @default_max_tokens,
      "messages" => to_messages(messages, opts[:images]),
      "stream" => true
    }

    base
    |> put_some("system", system(model, messages))
    |> put_some("tools", if(tools == [], do: nil, else: tools))
    |> put_some("temperature", opts[:temperature] || model.temperature)
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # The system prompt. With OAuth the Claude Code client block must come first, or the
  # subscription rejects the request; with an API key a plain string is enough.
  defp system(model, messages) do
    sys =
      messages
      |> Enum.find(&(&1["role"] == "system"))
      |> case do
        nil -> nil
        m -> to_string(m["content"] || "")
      end

    cond do
      oauth?(model) ->
        [%{"type" => "text", "text" => @client_id}] ++
          if(sys in [nil, ""], do: [], else: [%{"type" => "text", "text" => sys}])

      sys in [nil, ""] ->
        nil

      true ->
        sys
    end
  end

  # Chat messages -> Anthropic messages. Consecutive `tool` results merge into one user
  # turn (Anthropic requires tool results as user-role `tool_result` blocks).
  defp to_messages(messages, images) do
    messages
    # Attach on the ORIGINAL role=="user" turn (never a tool result, which is role "tool" here and
    # only becomes user-role below), so the image lands on the real user message, not a tool turn.
    |> attach_images_to_last_user(images)
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.reduce([], &add_message/2)
    |> Enum.reverse()
  end

  defp attach_images_to_last_user(messages, images) when images in [nil, []], do: messages

  defp attach_images_to_last_user(messages, images) do
    case messages |> Enum.with_index() |> Enum.filter(fn {m, _} -> m["role"] == "user" end) |> List.last() do
      {_m, idx} -> List.update_at(messages, idx, &Map.put(&1, "content", image_blocks(&1["content"], images)))
      nil -> messages
    end
  end

  # An Anthropic user turn with images: the text (if any) then one `image` source block each.
  defp image_blocks(text, images) do
    text_block = if is_binary(text) and text != "", do: [%{"type" => "text", "text" => text}], else: []

    text_block ++
      Enum.map(images, fn img ->
        %{"type" => "image", "source" => %{"type" => "base64", "media_type" => img.media_type, "data" => img.data}}
      end)
  end

  # Content may already be an image block list (from attach above) or a plain string.
  defp add_message(%{"role" => "user", "content" => content}, acc) when is_list(content) do
    [%{"role" => "user", "content" => content} | acc]
  end

  defp add_message(%{"role" => "user"} = m, acc) do
    [%{"role" => "user", "content" => to_string(m["content"] || "")} | acc]
  end

  defp add_message(%{"role" => "assistant", "tool_calls" => calls} = m, acc)
       when is_list(calls) and calls != [] do
    text =
      case m["content"] do
        c when is_binary(c) and c != "" -> [%{"type" => "text", "text" => c}]
        _ -> []
      end

    [%{"role" => "assistant", "content" => text ++ Enum.map(calls, &tool_use_block/1)} | acc]
  end

  defp add_message(%{"role" => "assistant"} = m, acc) do
    [%{"role" => "assistant", "content" => to_string(m["content"] || "")} | acc]
  end

  defp add_message(%{"role" => "tool"} = m, acc) do
    block = %{
      "type" => "tool_result",
      "tool_use_id" => m["tool_call_id"],
      "content" => to_string(m["content"] || "")
    }

    case acc do
      [%{"role" => "user", "content" => blocks} = u | rest] when is_list(blocks) ->
        [%{u | "content" => blocks ++ [block]} | rest]

      _ ->
        [%{"role" => "user", "content" => [block]} | acc]
    end
  end

  defp add_message(_, acc), do: acc

  defp tool_use_block(call) do
    %{
      "type" => "tool_use",
      "id" => call["id"],
      "name" => get_in(call, ["function", "name"]),
      "input" => decode_args(get_in(call, ["function", "arguments"]))
    }
  end

  defp decode_args(nil), do: %{}

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(map) when is_map(map), do: map
  defp decode_args(_), do: %{}

  # Chat-Completions tool specs -> Anthropic tools (`input_schema` instead of `parameters`).
  defp to_tools(nil), do: []

  defp to_tools(specs) when is_list(specs) do
    Enum.map(specs, fn
      %{"function" => f} ->
        %{
          "name" => f["name"],
          "description" => f["description"],
          "input_schema" => f["parameters"] || %{"type" => "object", "properties" => %{}}
        }

      other ->
        other
    end)
  end

  ###
  ### SSE parsing
  ###

  defp consume(data, state, on_delta) do
    case String.split(data, "\n") do
      [single] ->
        %{state | buffer: single}

      lines ->
        {complete, [partial]} = Enum.split(lines, -1)
        state = Enum.reduce(complete, state, &handle_line(&1, &2, on_delta))
        %{state | buffer: partial}
    end
  end

  defp handle_line(line, state, on_delta) do
    line = String.trim(line)

    cond do
      line == "" -> state
      not String.starts_with?(line, "data:") -> state
      true -> handle_data(String.trim(String.replace_prefix(line, "data:", "")), state, on_delta)
    end
  end

  defp handle_data(json, state, on_delta) do
    case Jason.decode(json) do
      {:ok, event} -> handle_event(event["type"], event, state, on_delta)
      _ -> state
    end
  end

  defp handle_event("message_start", %{"message" => msg}, state, _on_delta) do
    %{state | in: input_tokens(msg["usage"]) || state.in, cached: cache_read(msg["usage"]) || state.cached}
  end

  # A tool_use block opens: register it so its streamed JSON arguments accumulate.
  defp handle_event(
         "content_block_start",
         %{"index" => idx, "content_block" => %{"type" => "tool_use"} = block},
         state,
         _on_delta
       ) do
    entry = %{"id" => block["id"], "name" => block["name"], "json" => ""}
    %{state | blocks: Map.put(state.blocks, idx, entry), order: append_once(state.order, idx)}
  end

  defp handle_event("content_block_start", _event, state, _on_delta), do: state

  defp handle_event(
         "content_block_delta",
         %{"delta" => %{"type" => "text_delta", "text" => text}},
         state,
         on_delta
       )
       when is_binary(text) do
    on_delta.(text)
    %{state | content: state.content <> text}
  end

  defp handle_event(
         "content_block_delta",
         %{"index" => idx, "delta" => %{"type" => "input_json_delta", "partial_json" => frag}},
         state,
         _on_delta
       )
       when is_binary(frag) do
    update_block(state, idx, fn b -> %{b | "json" => (b["json"] || "") <> frag} end)
  end

  defp handle_event("content_block_delta", _event, state, _on_delta), do: state

  defp handle_event("message_delta", %{"delta" => delta} = event, state, _on_delta) do
    %{state | finish: map_stop(delta["stop_reason"]) || state.finish, out: output_tokens(event["usage"]) || state.out}
  end

  defp handle_event("error", event, state, _on_delta) do
    %{state | finish: "error", content: state.content <> error_text(event)}
  end

  defp handle_event(_type, _event, state, _on_delta), do: state

  defp input_tokens(%{"input_tokens" => n}) when is_integer(n), do: n
  defp input_tokens(_), do: nil

  # Anthropic reports cache-read input separately from `input_tokens` (which excludes it), so total
  # input = input + cache_read. Billing prices this portion at the cheaper cache rate.
  defp cache_read(%{"cache_read_input_tokens" => n}) when is_integer(n), do: n
  defp cache_read(_), do: nil

  defp output_tokens(%{"output_tokens" => n}) when is_integer(n), do: n
  defp output_tokens(_), do: nil

  defp error_text(%{"error" => %{"message" => m} = e}) when is_binary(m) do
    case e["type"] do
      t when is_binary(t) -> "#{t}: #{m}"
      _ -> m
    end
  end

  defp error_text(_), do: ""

  defp append_once(list, key), do: if(key in list, do: list, else: list ++ [key])

  defp update_block(state, idx, fun) do
    case Map.fetch(state.blocks, idx) do
      {:ok, block} -> %{state | blocks: Map.put(state.blocks, idx, fun.(block))}
      :error -> state
    end
  end

  defp map_stop("end_turn"), do: "stop"
  defp map_stop("stop_sequence"), do: "stop"
  defp map_stop("max_tokens"), do: "length"
  defp map_stop("tool_use"), do: "tool_calls"
  defp map_stop(_), do: nil

  # Flush a final SSE line the stream left un-terminated in the buffer (truncated stream or a
  # provider that doesn't newline-end its last frame), so its content/tool/error is not dropped. An
  # incomplete, undecodable line is a no-op.
  defp flush(state, on_delta) do
    case String.trim(state.buffer) do
      "" -> state
      _ -> handle_line(state.buffer, %{state | buffer: ""}, on_delta)
    end
  end

  defp finalize(state) do
    tool_calls =
      Enum.map(state.order, fn idx ->
        block = state.blocks[idx]
        args = block["json"]
        args = if args in [nil, ""], do: "{}", else: args

        %{
          "id" => block["id"],
          "type" => "function",
          "function" => %{"name" => block["name"], "arguments" => args}
        }
      end)

    %{
      content: (state.content != "" && state.content) || nil,
      tool_calls: tool_calls,
      finish_reason: if(tool_calls != [], do: "tool_calls", else: state.finish || "stop"),
      usage: usage_map(state)
    }
  end

  # `prompt_tokens` is TOTAL input (fresh + cache-read), so `cached_tokens` is a subset of it, as
  # billing expects. `cached_tokens` is only added when non-zero, keeping the map identical for a
  # call that hit no cache.
  defp usage_map(state) do
    prompt = state.in + state.cached

    base = %{
      "prompt_tokens" => prompt,
      "completion_tokens" => state.out,
      "total_tokens" => prompt + state.out
    }

    if state.cached > 0, do: Map.put(base, "cached_tokens", state.cached), else: base
  end
end
