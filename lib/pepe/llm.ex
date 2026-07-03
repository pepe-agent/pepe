defmodule Pepe.LLM do
  @moduledoc """
  OpenAI-compatible chat-completions client, built on `Req`.

  Talks to any provider that implements the `/chat/completions` protocol. The
  base URL, key, model and generation params come from an `Pepe.Config.Model`.

  Two entry points:

    * `chat/3`        - blocking request, returns the assembled message.
    * `stream_chat/4` - Server-Sent-Events streaming; invokes `on_delta` with each
                        text chunk as it arrives and returns the final assembled
                        message (including any tool calls).
  """

  alias Pepe.Config.Model

  @type result :: %{
          content: String.t() | nil,
          tool_calls: list(map()),
          finish_reason: String.t() | nil,
          usage: map() | nil
        }

  @doc """
  Perform a (non-streaming) chat completion.

  Options:
    * `:tools` - list of OpenAI tool/function specs
    * `:temperature`, `:max_tokens` - override the model defaults
    * `:extra` - extra body params merged verbatim
  """
  @spec chat(Model.t(), [map()], keyword()) :: {:ok, result()} | {:error, term()}
  def chat(model, messages, opts \\ [])

  def chat(%Model{api: "openai-responses"} = model, messages, opts),
    do: Pepe.LLM.Responses.chat(model, messages, opts)

  def chat(%Model{api: "anthropic-messages"} = model, messages, opts),
    do: Pepe.LLM.Messages.chat(model, messages, opts)

  def chat(%Model{} = model, messages, opts) do
    model = Pepe.OAuth.ensure_fresh(model)
    body = build_body(model, messages, opts, false)

    req =
      Req.new(
        url: chat_url(model),
        headers: headers(model),
        json: body,
        receive_timeout: opts[:receive_timeout] || 120_000,
        retry: :transient
      )

    case Req.post(req) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        {:ok, parse_completion(resp)}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streaming chat completion. `on_delta` is called with each text fragment
  (a binary). Returns `{:ok, result}` once the stream completes; the result
  carries the full assembled content plus any tool calls.
  """
  @spec stream_chat(Model.t(), [map()], (String.t() -> any()), keyword()) ::
          {:ok, result()} | {:error, term()}
  def stream_chat(model, messages, on_delta, opts \\ [])

  def stream_chat(%Model{api: "openai-responses"} = model, messages, on_delta, opts)
      when is_function(on_delta, 1),
      do: Pepe.LLM.Responses.stream_chat(model, messages, on_delta, opts)

  def stream_chat(%Model{api: "anthropic-messages"} = model, messages, on_delta, opts)
      when is_function(on_delta, 1),
      do: Pepe.LLM.Messages.stream_chat(model, messages, on_delta, opts)

  def stream_chat(%Model{} = model, messages, on_delta, opts)
      when is_function(on_delta, 1) do
    model = Pepe.OAuth.ensure_fresh(model)
    body = build_body(model, messages, opts, true)
    init = %{buffer: "", content: "", tool_calls: %{}, finish: nil, usage: nil, raw: ""}

    collector = fn {:data, data}, {req, resp} ->
      state = resp.private[:pepe] || init
      state = consume(state.buffer <> data, %{state | buffer: ""}, on_delta)
      # Keep a bounded copy of the raw stream. `into:` hands the body to the collector for a
      # non-2xx status too, and there the parsed SSE state is empty - the error body is the only
      # place a provider says *why* (an over-`max_tokens` reservation, say), which the runtime's
      # output-cap retry reads. Capped so a large successful stream is not doubled in memory.
      state = %{state | raw: cap_raw(state.raw <> data)}
      {:cont, {req, %{resp | private: Map.put(resp.private, :pepe, state)}}}
    end

    req =
      Req.new(
        url: chat_url(model),
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
        # stream produced no data frames
        {:ok, finalize(resp.private[:pepe] || init)}

      {:ok, %{status: status} = resp} ->
        # The error body was streamed into the collector (not `resp.body`, which `into:` leaves
        # empty), so read it back from there.
        {:error, {:http_error, status, (resp.private[:pepe] || init).raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List the model ids the provider advertises via `GET {base_url}/models`.
  Returns `{:ok, [id, ...]}` (sorted) or `{:error, reason}`.
  """
  @spec list_models(Model.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_models(%Model{api: "openai-responses"} = model),
    do: Pepe.LLM.Responses.list_models(model)

  def list_models(%Model{api: "anthropic-messages"} = model),
    do: Pepe.LLM.Messages.list_models(model)

  def list_models(%Model{} = model) do
    url = String.trim_trailing(model.base_url, "/") <> "/models"

    case Req.get(url, headers: headers(model), receive_timeout: 30_000, retry: :transient) do
      {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 ->
        ids = data |> Enum.map(&(&1["id"] || &1["name"])) |> Enum.reject(&is_nil/1) |> Enum.sort()
        {:ok, ids}

      {:ok, %{status: status, body: body}} when status in 200..299 and is_list(body) ->
        ids = body |> Enum.map(&(&1["id"] || &1["name"])) |> Enum.reject(&is_nil/1) |> Enum.sort()
        {:ok, ids}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ###
  ### request building
  ###

  defp chat_url(%Model{base_url: base}),
    do: String.trim_trailing(base, "/") <> "/chat/completions"

  defp headers(%Model{} = model) do
    base = %{"content-type" => "application/json"}

    base =
      case Model.resolved_api_key(model) do
        nil -> base
        "" -> base
        key -> Map.put(base, "authorization", "Bearer " <> key)
      end

    Map.merge(base, Model.resolved_headers(model))
  end

  defp build_body(%Model{} = model, messages, opts, stream?) do
    %{"model" => model.model, "messages" => with_images(messages, opts[:images])}
    |> put_some("tools", opts[:tools])
    |> put_some("temperature", opts[:temperature] || model.temperature)
    |> put_some("max_tokens", opts[:max_tokens] || model.max_tokens)
    |> then(fn b -> if stream?, do: Map.put(b, "stream", true), else: b end)
    |> then(fn b ->
      if stream?, do: Map.put(b, "stream_options", %{"include_usage" => true}), else: b
    end)
    |> Map.merge(opts[:extra] || %{})
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, _key, []), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # Attach any inbound images to the LAST user message, in OpenAI content-part form. Send-time only:
  # the images ride in `opts` for this turn and never touch the persisted string history.
  defp with_images(messages, images) when images in [nil, []], do: messages

  defp with_images(messages, images) do
    case messages |> Enum.with_index() |> Enum.filter(fn {m, _} -> m["role"] == "user" end) |> List.last() do
      {_m, idx} -> List.update_at(messages, idx, &attach_openai_images(&1, images))
      nil -> messages
    end
  end

  defp attach_openai_images(msg, images) do
    text = to_string(msg["content"] || "")
    text_part = if text == "", do: [], else: [%{"type" => "text", "text" => text}]
    image_parts = Enum.map(images, &%{"type" => "image_url", "image_url" => %{"url" => Pepe.LLM.Image.data_uri(&1)}})
    Map.put(msg, "content", text_part ++ image_parts)
  end

  ###
  ### non-streaming parsing
  ###

  defp parse_completion(resp) when is_binary(resp) do
    resp
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> parse_completion(decoded)
      {:error, _} -> %{content: resp, tool_calls: [], finish_reason: "error", usage: nil}
    end
  end

  defp parse_completion(%{"choices" => [choice | _]} = resp) do
    message = choice["message"] || %{}

    %{
      content: message["content"],
      tool_calls: message["tool_calls"] || [],
      finish_reason: choice["finish_reason"],
      usage: resp["usage"]
    }
  end

  defp parse_completion(resp),
    do: %{content: inspect(resp), tool_calls: [], finish_reason: "error", usage: nil}

  ###
  ### SSE streaming parsing
  ###

  # Split into complete lines, keep the trailing partial in the buffer.
  # Enough of the raw stream to carry an error body (a provider's "why"); a success body is much
  # larger and never needed here, so cap it rather than double the stream in memory.
  @max_raw 8192
  defp cap_raw(raw) when byte_size(raw) > @max_raw, do: binary_part(raw, 0, @max_raw)
  defp cap_raw(raw), do: raw

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

  defp handle_data("[DONE]", state, _on_delta), do: state

  defp handle_data(json, state, on_delta) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [choice | _]} = chunk} ->
        delta = choice["delta"] || %{}
        state = apply_content_delta(delta["content"], state, on_delta)
        state = apply_tool_call_deltas(delta["tool_calls"], state)

        state =
          if choice["finish_reason"], do: %{state | finish: choice["finish_reason"]}, else: state

        if chunk["usage"], do: %{state | usage: chunk["usage"]}, else: state

      {:ok, %{"usage" => usage}} ->
        %{state | usage: usage}

      # A 200 stream can still carry a top-level error frame (`data: {"error": {...}}`) instead of
      # choices. Mark the turn failed so it surfaces as an error, not an empty success, and fold the
      # provider's reason into content so it says *why* (see `Pepe.Agent.Runtime`).
      {:ok, %{"error" => _} = chunk} ->
        %{state | finish: "error", content: error_text(chunk) || state.content}

      _ ->
        state
    end
  end

  # The provider's reason from an error frame - `error.{code|type}` + `error.message`.
  defp error_text(%{"error" => %{"message" => m} = e}) when is_binary(m) do
    case e["code"] || e["type"] do
      code when is_binary(code) -> "#{code}: #{m}"
      _ -> m
    end
  end

  defp error_text(_), do: nil

  defp apply_content_delta(nil, state, _on_delta), do: state
  defp apply_content_delta("", state, _on_delta), do: state

  defp apply_content_delta(text, state, on_delta) do
    on_delta.(text)
    %{state | content: state.content <> text}
  end

  defp apply_tool_call_deltas(nil, state), do: state

  defp apply_tool_call_deltas(deltas, state) when is_list(deltas) do
    tool_calls = Enum.reduce(deltas, state.tool_calls, &merge_tool_call/2)
    %{state | tool_calls: tool_calls}
  end

  defp merge_tool_call(d, acc) do
    idx = bucket_index(d, acc)
    existing = Map.get(acc, idx, empty_tool_call())

    merged = %{
      "id" => d["id"] || existing["id"],
      "type" => d["type"] || existing["type"] || "function",
      "function" => merge_tool_fun(existing["function"], d["function"] || %{})
    }

    Map.put(acc, idx, merged)
  end

  # Which accumulator bucket a streamed tool-call delta belongs to. OpenAI sends an `index` on
  # every fragment (the common path, unchanged). A non-conforming provider may omit it and stream
  # parallel calls; keying them all to `0` (the old `d["index"] || 0`) concatenated distinct calls
  # into one garbled call. Without an index: a delta carrying an `id` opens/reuses that call's own
  # bucket, and an id-less, index-less argument fragment continues the most recently opened one.
  defp bucket_index(%{"index" => idx}, _acc) when is_integer(idx), do: idx

  defp bucket_index(%{"id" => id}, acc) when is_binary(id) and id != "" do
    case Enum.find(acc, fn {_i, tc} -> tc["id"] == id end) do
      {i, _} -> i
      nil -> next_index(acc)
    end
  end

  defp bucket_index(_d, acc), do: max_index(acc) || 0

  defp next_index(acc), do: (max_index(acc) || -1) + 1

  defp max_index(acc) when map_size(acc) == 0, do: nil
  defp max_index(acc), do: acc |> Map.keys() |> Enum.max()

  defp empty_tool_call,
    do: %{"id" => nil, "type" => "function", "function" => %{"name" => "", "arguments" => ""}}

  defp merge_tool_fun(fun, d_fun) do
    %{
      "name" => (fun["name"] || "") <> (d_fun["name"] || ""),
      "arguments" => (fun["arguments"] || "") <> (d_fun["arguments"] || "")
    }
  end

  # Process a final SSE line the stream left in the buffer with no trailing newline. `consume/3`
  # parks the trailing partial in `state.buffer`; if the last frame arrived un-terminated (a
  # truncated stream, or a provider that doesn't newline-end its final frame), its content/tool/error
  # would otherwise be silently dropped. A genuinely partial (undecodable) line decodes to nothing
  # and is a no-op.
  defp flush(state, on_delta) do
    case String.trim(state.buffer) do
      "" -> state
      _ -> handle_line(state.buffer, %{state | buffer: ""}, on_delta)
    end
  end

  defp finalize(state) do
    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, tc} -> tc end)

    %{
      content: (state.content != "" && state.content) || nil,
      tool_calls: tool_calls,
      finish_reason: state.finish,
      usage: state.usage
    }
  end
end
