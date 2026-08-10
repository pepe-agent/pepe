defmodule Pepe.Otel do
  @moduledoc """
  Opt-in OTLP/HTTP export of a finished `Pepe.Trace` row, for whoever wants their runs
  in an observability tool - Langfuse, Honeycomb, Datadog, anything that speaks OTLP.
  Off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set; every other Pepe feature is unaffected
  either way, and a delivery failure here never touches the run it's describing.

  Deliberately a hand-built OTLP/HTTP+JSON payload over `Req` (already a dependency),
  not the `opentelemetry`/`opentelemetry_exporter` Erlang SDK: that SDK is built to
  instrument *live* code as it runs (spans opened and closed inline, wired into the
  supervision tree), which is real weight for a job that is actually "take one already-
  finished trace and serialize it" - a single POST per completed run, not a running
  span pipeline. Pulling in the batching processor, its own process tree and the
  gRPC/protobuf stack it drags with it would buy nothing that hand-building the (fairly
  small) JSON body here doesn't already cover, at zero added dependency weight.

  ## Attribute conventions

  Both sets are set on every span so this stays useful beyond one destination:

    * Generic OpenTelemetry GenAI semantic conventions (`gen_ai.*`) - understood by any
      OTLP-speaking backend.
    * Langfuse's own `langfuse.*` attributes (session, user, observation input/output/
      type) - Langfuse's docs say these take precedence over the generic ones when both
      are present, so setting both costs nothing and makes a Langfuse endpoint render
      fully (session grouping, input/output panes, generation vs. plain-span
      distinction) instead of a bare list of unlabeled spans.

  One span per trace, one child span per tool call and per model call (a "usage" event
  in the trace - a run can hold more than one on failover/triage). A tool call's
  arguments/result and the root span's prompt/final reply become the observation input/
  output; nothing in a trace maps to a per-model-call prompt/completion (the trace
  model doesn't record one at that granularity), so a generation span carries usage and
  timing but no separate transcript - the root span's input/output already cover that
  for the run as a whole. Child spans are laid out in event order across the parent's
  own start/duration window (events carry no timestamp of their own to place them by),
  so ordering in a waterfall view is correct even though exact per-event timing isn't.
  """

  require Logger

  @doc "Is an OTLP endpoint configured? Checked once per export, not cached - reading a
  couple of env vars costs nothing and this only runs once per finished trace."
  @spec enabled? :: boolean()
  def enabled? do
    case endpoint() do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc """
  Export a finished trace `row` (the same map `Pepe.Trace.finish/1` writes) as one
  OTLP trace. Fire-and-forget: never raises into the caller, logs and drops on failure.
  No-op when `enabled?/0` is false, so a caller doesn't need to check first.
  """
  @spec export(map()) :: :ok
  def export(row) do
    if enabled?() do
      Task.start(fn -> do_export(row) end)
    end

    :ok
  end

  defp do_export(row) do
    body = Jason.encode!(payload(row))

    Req.post(traces_url(),
      body: body,
      headers: [{"content-type", "application/json"} | header_pairs()],
      retry: false,
      receive_timeout: 10_000
    )
    |> case do
      {:ok, %{status: s}} when s in 200..299 ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.warning("[otel] export rejected (#{s}): #{inspect(b) |> String.slice(0, 300)}")

      {:error, reason} ->
        Logger.warning("[otel] export failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[otel] export raised: #{Exception.message(e)}")
  end

  # --- config --------------------------------------------------------------------

  defp endpoint, do: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

  # The signal-specific var, when set, is used exactly as given (the OTEL spec's own
  # rule: it already points at the traces endpoint, nothing gets appended). The general
  # var gets "/v1/traces" appended, same as every standard OTLP/HTTP exporter.
  defp traces_url do
    case System.get_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") do
      nil -> String.trim_trailing(endpoint(), "/") <> "/v1/traces"
      "" -> String.trim_trailing(endpoint(), "/") <> "/v1/traces"
      specific -> specific
    end
  end

  # OTEL_EXPORTER_OTLP_HEADERS: "k1=v1,k2=v2" - the standard format every OTLP SDK
  # reads, so e.g. `Authorization=Basic <base64>` for Langfuse's basic auth works with
  # no Langfuse-specific code here at all.
  defp header_pairs do
    (System.get_env("OTEL_EXPORTER_OTLP_HEADERS") || "")
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
  end

  defp service_name, do: System.get_env("OTEL_SERVICE_NAME") || "pepe"

  # --- payload ---------------------------------------------------------------------

  defp payload(row) do
    trace_id = trace_id(row)
    {start_ns, end_ns} = window(row)
    root_id = span_id()

    spans = [root_span(row, trace_id, root_id, start_ns, end_ns) | child_spans(row, trace_id, root_id, start_ns, end_ns)]

    %{
      "resourceSpans" => [
        %{
          "resource" => %{"attributes" => [attr("service.name", service_name())]},
          "scopeSpans" => [%{"scope" => %{"name" => "pepe"}, "spans" => spans}]
        }
      ]
    }
  end

  defp root_span(row, trace_id, span_id, start_ns, end_ns) do
    events = row[:events] || []
    reply = final_reply(events)
    ok? = get_in(row, [:outcome, "kind"]) == "ok"

    base_attrs = [
      attr("langfuse.trace.name", row[:agent] || "pepe"),
      attr("gen_ai.system", "pepe")
    ]

    session_attrs =
      case row[:session] do
        nil -> []
        s -> [attr("langfuse.session.id", s), attr("session.id", s)]
      end

    io_attrs =
      [
        {"langfuse.observation.input", row[:prompt]},
        {"gen_ai.prompt", row[:prompt]},
        {"langfuse.observation.output", reply},
        {"gen_ai.completion", reply}
      ]
      |> Enum.filter(fn {_, v} -> v not in [nil, ""] end)
      |> Enum.map(fn {k, v} -> attr(k, v) end)

    %{
      "traceId" => trace_id,
      "spanId" => span_id,
      "name" => "pepe.run",
      "kind" => 1,
      "startTimeUnixNano" => to_string(start_ns),
      "endTimeUnixNano" => to_string(end_ns),
      "attributes" => base_attrs ++ session_attrs ++ io_attrs,
      "status" => %{"code" => if(ok?, do: 1, else: 2)}
    }
  end

  defp final_reply(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"t" => "assistant", "text" => text} -> text
      _ -> nil
    end)
  end

  defp child_spans(row, trace_id, parent_id, start_ns, end_ns) do
    events = row[:events] || []
    n = max(length(events), 1)
    span_window_ns = max(div(end_ns - start_ns, n), 1)

    tool_results = for %{"t" => "tool_result"} = e <- events, do: e

    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, i} ->
      t0 = start_ns + i * span_window_ns
      t1 = min(t0 + span_window_ns, end_ns)
      event_span(event, i, tool_results, trace_id, parent_id, t0, t1)
    end)
  end

  defp event_span(%{"t" => "tool_call", "name" => name, "args" => args}, i, tool_results, trace_id, parent_id, t0, t1) do
    out = tool_results |> Enum.at(0, %{}) |> Map.get("out")

    [
      %{
        "traceId" => trace_id,
        "spanId" => span_id(),
        "parentSpanId" => parent_id,
        "name" => name,
        "kind" => 3,
        "startTimeUnixNano" => to_string(t0),
        "endTimeUnixNano" => to_string(t1),
        "attributes" =>
          [attr("langfuse.observation.type", "span"), attr("gen_ai.tool.name", name)] ++
            io_attr("langfuse.observation.input", args, i) ++ io_attr("langfuse.observation.output", out, i),
        "status" => %{"code" => 1}
      }
    ]
  end

  defp event_span(%{"t" => "usage", "model" => model, "in" => in_tok, "out" => out_tok}, _i, _tool_results, trace_id, parent_id, t0, t1) do
    [
      %{
        "traceId" => trace_id,
        "spanId" => span_id(),
        "parentSpanId" => parent_id,
        "name" => model || "generation",
        "kind" => 3,
        "startTimeUnixNano" => to_string(t0),
        "endTimeUnixNano" => to_string(t1),
        "attributes" =>
          [attr("langfuse.observation.type", "generation"), attr("gen_ai.system", "pepe")] ++
            model_attrs(model) ++ token_attrs(in_tok, out_tok),
        "status" => %{"code" => 1}
      }
    ]
  end

  defp event_span(_other, _i, _tool_results, _trace_id, _parent_id, _t0, _t1), do: []

  defp model_attrs(nil), do: []
  defp model_attrs(model), do: [attr("gen_ai.request.model", model), attr("langfuse.observation.model.name", model)]

  defp token_attrs(in_tok, out_tok) do
    [{"gen_ai.usage.input_tokens", in_tok}, {"gen_ai.usage.output_tokens", out_tok}]
    |> Enum.filter(fn {_, v} -> is_integer(v) end)
    |> Enum.map(fn {k, v} -> attr(k, v) end)
  end

  # A tool_call event is only paired with the tool_result at the SAME index in
  # practice (the runtime always emits them back to back), but events here are
  # already flattened - use the i-th tool_result as a best-effort match rather than
  # assuming list order lines up exactly across event types.
  defp io_attr(_key, nil, _i), do: []
  defp io_attr(key, value, _i) when is_binary(value), do: [attr(key, value)]
  defp io_attr(key, value, _i), do: [attr(key, inspect(value))]

  # int64 fields (AnyValue.int_value) are protobuf `int64`, whose canonical JSON
  # mapping is a decimal STRING, not a JSON number (avoids precision loss past JS's
  # 53-bit safe integer range) - a compliant receiver must accept either, but this
  # sends the actually-correct form rather than leaning on that leniency.
  defp attr(key, value) when is_binary(value), do: %{"key" => key, "value" => %{"stringValue" => value}}
  defp attr(key, value) when is_integer(value), do: %{"key" => key, "value" => %{"intValue" => to_string(value)}}
  defp attr(key, value) when is_boolean(value), do: %{"key" => key, "value" => %{"boolValue" => value}}
  defp attr(key, value), do: %{"key" => key, "value" => %{"stringValue" => to_string(value)}}

  # --- ids ---------------------------------------------------------------------

  # Deterministic from Pepe's own trace id, so retrying/re-exporting the same trace
  # (there is no such caller today, but nothing rules one out later) lands on the same
  # OTEL trace instead of creating an orphaned duplicate.
  defp trace_id(%{id: id}) when is_binary(id), do: :crypto.hash(:sha256, id) |> binary_part(0, 16) |> Base.encode16(case: :lower)
  defp trace_id(_), do: span_id() <> span_id()

  defp span_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp window(row) do
    start_ns = (row[:at] || 0) * 1_000_000_000
    end_ns = start_ns + (row[:ms] || 0) * 1_000_000
    {start_ns, max(end_ns, start_ns + 1)}
  end
end
