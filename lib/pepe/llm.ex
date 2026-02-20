defmodule Pepe.LLM do
  @moduledoc """
  OpenAI-compatible chat-completions client, built on `Req`.

  Talks to any provider that implements the `/chat/completions` protocol. The
  base URL, key, model and generation params come from an `Pepe.Config.Model`.

  Two entry points:

    * `chat/3`        — blocking request, returns the assembled message.
    * `stream_chat/4` — Server-Sent-Events streaming; invokes `on_delta` with each
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
    * `:tools` — list of OpenAI tool/function specs
    * `:temperature`, `:max_tokens` — override the model defaults
    * `:extra` — extra body params merged verbatim
  """
  @spec chat(Model.t(), [map()], keyword()) :: {:ok, result()} | {:error, term()}
  def chat(model, messages, opts \\ [])

  def chat(%Model{api: "openai-responses"} = model, messages, opts),
    do: Pepe.LLM.Responses.chat(model, messages, opts)

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

  def stream_chat(%Model{} = model, messages, on_delta, opts)
      when is_function(on_delta, 1) do
    model = Pepe.OAuth.ensure_fresh(model)
    body = build_body(model, messages, opts, true)
    init = %{buffer: "", content: "", tool_calls: %{}, finish: nil, usage: nil}

    collector = fn {:data, data}, {req, resp} ->
      state = resp.private[:pepe] || init
      state = consume(state.buffer <> data, %{state | buffer: ""}, on_delta)
      {:cont, {req, %{resp | private: Map.put(resp.private, :pepe, state)}}}
    end

    req =
      Req.new(
        url: chat_url(model),
        headers: headers(model),
        json: body,
        receive_timeout: opts[:receive_timeout] || 120_000,
        into: collector
      )

    case Req.post(req) do
      {:ok, %{status: status, private: %{pepe: state}}} when status in 200..299 ->
        {:ok, finalize(state)}

      {:ok, %{status: status} = resp} when status in 200..299 ->
        # stream produced no data frames
        {:ok, finalize(resp.private[:pepe] || init)}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

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
    %{"model" => model.model, "messages" => messages}
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

  ###
  ### non-streaming parsing
  ###

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

      _ ->
        state
    end
  end

  defp apply_content_delta(nil, state, _on_delta), do: state
  defp apply_content_delta("", state, _on_delta), do: state

  defp apply_content_delta(text, state, on_delta) do
    on_delta.(text)
    %{state | content: state.content <> text}
  end

  defp apply_tool_call_deltas(nil, state), do: state

  defp apply_tool_call_deltas(deltas, state) when is_list(deltas) do
    tool_calls =
      Enum.reduce(deltas, state.tool_calls, fn d, acc ->
        idx = d["index"] || 0

        existing =
          Map.get(acc, idx, %{
            "id" => nil,
            "type" => "function",
            "function" => %{"name" => "", "arguments" => ""}
          })

        fun = existing["function"]
        d_fun = d["function"] || %{}

        merged_fun = %{
          "name" => (fun["name"] || "") <> (d_fun["name"] || ""),
          "arguments" => (fun["arguments"] || "") <> (d_fun["arguments"] || "")
        }

        merged = %{
          "id" => d["id"] || existing["id"],
          "type" => d["type"] || existing["type"] || "function",
          "function" => merged_fun
        }

        Map.put(acc, idx, merged)
      end)

    %{state | tool_calls: tool_calls}
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
