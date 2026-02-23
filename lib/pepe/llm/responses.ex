defmodule Pepe.LLM.Responses do
  @moduledoc """
  Adapter for the OpenAI **Responses API** used by the ChatGPT/Codex subscription
  (`https://chatgpt.com/backend-api/codex/responses`). It speaks a different shape
  than Chat Completions, so this module translates on both ends:

    * inbound  - Pepe's OpenAI chat-format `messages`/`tools` -> Responses
      `instructions` + `input` items + flat `tools`.
    * outbound - the SSE `response.*` event stream -> the same
      `%{content, tool_calls, finish_reason, usage}` result `Pepe.LLM` returns,
      with `tool_calls` in Chat-Completions shape so the runtime is unchanged.

  Auth: the access token (a JWT) is the bearer; the `chatgpt-account-id` header is
  read from the token's `"https://api.openai.com/auth".chatgpt_account_id` claim.
  Dispatched from `Pepe.LLM` when `model.api == "openai-responses"`.
  """

  alias Pepe.Config.Model

  @originator "pepe"
  @auth_claim "https://api.openai.com/auth"

  @doc "Non-streaming: the endpoint only streams, so we collect the stream."
  def chat(%Model{} = model, messages, opts \\ []) do
    stream_chat(model, messages, fn _ -> :ok end, opts)
  end

  @doc "Streaming Responses call. `on_delta` receives each assistant text fragment."
  def stream_chat(%Model{} = model, messages, on_delta, opts \\ [])
      when is_function(on_delta, 1) do
    model = Pepe.OAuth.ensure_fresh(model)
    body = build_body(model, messages, opts)
    init = %{buffer: "", content: "", calls: %{}, order: [], finish: nil, usage: nil, raw: ""}

    collector = fn {:data, data}, {req, resp} ->
      state = resp.private[:pepe] || init
      # Keep the raw bytes too - on a non-2xx the error body lands here (not in
      # `resp.body`), and we want to surface what the provider actually said.
      state = %{state | raw: state.raw <> data}
      state = consume(state.buffer <> data, %{state | buffer: ""}, on_delta)
      {:cont, {req, %{resp | private: Map.put(resp.private, :pepe, state)}}}
    end

    req =
      Req.new(
        url: responses_url(model),
        headers: headers(model),
        json: body,
        receive_timeout: opts[:receive_timeout] || 120_000,
        into: collector
      )

    case Req.post(req) do
      {:ok, %{status: status, private: %{pepe: state}}} when status in 200..299 ->
        {:ok, finalize(state)}

      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, finalize(resp.private[:pepe] || init)}

      # Non-2xx: the body was streamed into the collector, so read it from there.
      {:ok, %{status: status, private: %{pepe: %{raw: raw}}}} ->
        {:error, {:http_error, status, raw}}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List the model ids the Codex/ChatGPT subscription exposes, via
  `GET {base}/codex/models?client_version=1.0.0` (the endpoint has no standard
  `/v1/models`). Filters out rows the picker should hide. Returns `{:ok, ids}`.
  """
  def list_models(%Model{} = model) do
    headers = Map.put(headers(model), "accept", "application/json")

    case Req.get(models_url(model), headers: headers, receive_timeout: 30_000, retry: :transient) do
      {:ok, %{status: status, body: %{"models" => rows}}}
      when status in 200..299 and is_list(rows) ->
        ids =
          rows
          |> Enum.filter(&listable?/1)
          |> Enum.map(&model_id/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok, ids}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listable?(row) do
    visibility = row |> Map.get("visibility", "") |> to_string() |> String.downcase()
    visible? = visibility in ["", "list"]
    in_picker? = Map.get(row, "show_in_picker", Map.get(row, "showInPicker", true))
    visible? and in_picker? != false
  end

  defp model_id(row), do: row["id"] || row["slug"] || row["model"] || row["name"]

  ###
  ### URL + headers
  ###

  # Normalised `.../codex` base (handles base URLs given with or without the
  # `/codex` or `/codex/responses` suffix).
  defp codex_base(%Model{base_url: base}) do
    base = String.trim_trailing(base, "/")

    cond do
      String.ends_with?(base, "/codex/responses") -> String.replace_suffix(base, "/responses", "")
      String.ends_with?(base, "/codex") -> base
      true -> base <> "/codex"
    end
  end

  defp responses_url(model), do: codex_base(model) <> "/responses"
  defp models_url(model), do: codex_base(model) <> "/models?client_version=1.0.0"

  defp headers(%Model{} = model) do
    token = Model.resolved_api_key(model) || ""

    %{
      "authorization" => "Bearer " <> token,
      "originator" => @originator,
      "openai-beta" => "responses=experimental",
      "accept" => "text/event-stream",
      "content-type" => "application/json"
    }
    |> put_account_id(token)
    |> Map.merge(Model.resolved_headers(model))
  end

  defp put_account_id(headers, token) do
    case account_id(token) do
      nil -> headers
      id -> Map.put(headers, "chatgpt-account-id", id)
    end
  end

  # Decode the JWT payload (base64url, unsigned) and read the account id claim.
  defp account_id(token) do
    with [_header, payload | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json),
         %{"chatgpt_account_id" => id} when is_binary(id) <- claims[@auth_claim] do
      id
    else
      _ -> nil
    end
  end

  ###
  ### request body
  ###

  defp build_body(%Model{} = model, messages, opts) do
    {instructions, input} = split_system(messages)
    tools = to_tools(opts[:tools])

    base = %{
      "model" => model.model,
      "store" => false,
      "stream" => true,
      "instructions" => instructions || "You are a helpful assistant.",
      "input" => input,
      "include" => ["reasoning.encrypted_content"]
    }

    base =
      if tools == [] do
        base
      else
        Map.merge(base, %{
          "tools" => tools,
          "tool_choice" => "auto",
          "parallel_tool_calls" => true
        })
      end

    case opts[:temperature] || model.temperature do
      nil -> base
      t -> Map.put(base, "temperature", t)
    end
  end

  # The system prompt becomes `instructions`; the rest becomes `input` items.
  defp split_system(messages) do
    system =
      messages
      |> Enum.find(&(&1["role"] == "system"))
      |> case do
        nil -> nil
        msg -> to_string(msg["content"] || "")
      end

    input =
      messages
      |> Enum.reject(&(&1["role"] == "system"))
      |> Enum.flat_map(&input_items/1)

    {system, input}
  end

  defp input_items(%{"role" => "user", "content" => content}) do
    [%{"type" => "message", "role" => "user", "content" => [text_part("input_text", content)]}]
  end

  defp input_items(%{"role" => "assistant", "tool_calls" => calls} = msg)
       when is_list(calls) and calls != [] do
    text =
      case msg["content"] do
        c when is_binary(c) and c != "" -> [assistant_text(c)]
        _ -> []
      end

    text ++ Enum.map(calls, &function_call_item/1)
  end

  defp input_items(%{"role" => "assistant", "content" => content}) do
    [assistant_text(to_string(content || ""))]
  end

  defp input_items(%{"role" => "tool", "tool_call_id" => id, "content" => content}) do
    [%{"type" => "function_call_output", "call_id" => id, "output" => to_string(content)}]
  end

  defp input_items(_), do: []

  defp assistant_text(text) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}],
      "status" => "completed"
    }
  end

  defp function_call_item(call) do
    %{
      "type" => "function_call",
      "call_id" => call["id"],
      "name" => get_in(call, ["function", "name"]),
      "arguments" => get_in(call, ["function", "arguments"]) || "{}"
    }
  end

  defp text_part(type, content), do: %{"type" => type, "text" => to_string(content)}

  # Chat-Completions tool specs (nested under "function") -> flat Responses tools.
  defp to_tools(nil), do: []

  defp to_tools(specs) when is_list(specs) do
    Enum.map(specs, fn
      %{"function" => f} ->
        %{
          "type" => "function",
          "name" => f["name"],
          "description" => f["description"],
          "parameters" => f["parameters"]
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

  defp handle_data("[DONE]", state, _on_delta), do: state

  defp handle_data(json, state, on_delta) do
    case Jason.decode(json) do
      {:ok, event} -> handle_event(event["type"], event, state, on_delta)
      _ -> state
    end
  end

  # assistant text
  defp handle_event("response.output_text.delta", %{"delta" => delta}, state, on_delta)
       when is_binary(delta) do
    on_delta.(delta)
    %{state | content: state.content <> delta}
  end

  # a new output item - register function calls so we can stream their arguments
  defp handle_event(
         "response.output_item.added",
         %{"item" => %{"type" => "function_call"} = item},
         state,
         _on_delta
       ) do
    key = item["id"] || item["call_id"]

    call = %{
      "call_id" => item["call_id"],
      "name" => item["name"],
      "arguments" => item["arguments"] || ""
    }

    %{state | calls: Map.put(state.calls, key, call), order: append_once(state.order, key)}
  end

  # streamed tool-call argument fragments
  defp handle_event(
         "response.function_call_arguments.delta",
         %{"item_id" => key, "delta" => delta},
         state,
         _on_delta
       ) do
    update_call(state, key, fn c -> %{c | "arguments" => (c["arguments"] || "") <> delta} end)
  end

  # authoritative final arguments
  defp handle_event(
         "response.function_call_arguments.done",
         %{"item_id" => key, "arguments" => args},
         state,
         _on_delta
       ) do
    update_call(state, key, fn c -> %{c | "arguments" => args} end)
  end

  # terminal events (response.done / response.incomplete are aliases)
  defp handle_event(type, %{"response" => response}, state, _on_delta)
       when type in ["response.completed", "response.done", "response.incomplete"] do
    %{state | finish: map_status(response["status"]), usage: response["usage"] || state.usage}
  end

  defp handle_event(type, %{"response" => response}, state, _on_delta)
       when type in ["response.failed", "error"] do
    %{state | finish: "error", usage: response["usage"] || state.usage}
  end

  defp handle_event("error", _event, state, _on_delta), do: %{state | finish: "error"}

  defp handle_event(_type, _event, state, _on_delta), do: state

  defp append_once(list, key), do: if(key in list, do: list, else: list ++ [key])

  defp update_call(state, key, fun) do
    case Map.fetch(state.calls, key) do
      {:ok, call} -> %{state | calls: Map.put(state.calls, key, fun.(call))}
      :error -> state
    end
  end

  defp map_status("completed"), do: "stop"
  defp map_status("incomplete"), do: "length"
  defp map_status("failed"), do: "error"
  defp map_status("cancelled"), do: "error"
  defp map_status(_), do: "stop"

  defp finalize(state) do
    tool_calls =
      Enum.map(state.order, fn key ->
        call = state.calls[key]

        %{
          "id" => call["call_id"],
          "type" => "function",
          "function" => %{"name" => call["name"], "arguments" => call["arguments"] || "{}"}
        }
      end)

    %{
      content: (state.content != "" && state.content) || nil,
      tool_calls: tool_calls,
      finish_reason: if(tool_calls != [], do: "tool_calls", else: state.finish),
      usage: state.usage
    }
  end
end
