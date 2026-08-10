defmodule Pepe.OtelTest do
  # async: false - System.put_env/2 (OTEL_EXPORTER_OTLP_*) is process-wide, and the
  # mock collector registers a fixed process name.
  use ExUnit.Case, async: false

  alias Pepe.Otel

  setup do
    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockOtelCollector, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    prev =
      for k <- ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS), do: {k, System.get_env(k)}

    on_exit(fn ->
      Process.exit(server, :normal)

      Enum.each(prev, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    Pepe.Test.MockOtelCollector.listen()
    {:ok, port: port}
  end

  defp sample_row do
    %{
      id: "trace123",
      scope: "root",
      at: 1_700_000_000,
      agent: "assistant",
      session: "telegram:555",
      source: "telegram",
      prompt: "what's the weather",
      ms: 1200,
      outcome: %{"kind" => "ok"},
      events: [
        %{"t" => "tool_call", "name" => "web_search", "args" => "weather today"},
        %{"t" => "tool_result", "name" => "web_search", "out" => "sunny, 22C"},
        %{"t" => "usage", "model" => "gpt-4o", "in" => 120, "out" => 40},
        %{"t" => "assistant", "text" => "It's sunny and 22C."}
      ]
    }
  end

  test "enabled?/0 is false with no endpoint configured" do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    refute Otel.enabled?()
  end

  test "enabled?/0 is true once an endpoint is set" do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:1")
    assert Otel.enabled?()
  end

  test "export/1 is a no-op (no HTTP call at all) when disabled" do
    System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    assert Otel.export(sample_row()) == :ok
    refute_receive {:otel_request, _, _}, 200
  end

  test "export/1 posts a valid OTLP payload with root + tool + generation spans", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    assert Otel.export(sample_row()) == :ok
    assert_receive {:otel_request, headers, body}, 2000

    assert {"content-type", "application/json"} in headers

    [%{"resource" => resource, "scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    assert [%{"key" => "service.name", "value" => %{"stringValue" => "pepe"}}] = resource["attributes"]

    root = Enum.find(spans, &(&1["name"] == "pepe.run"))
    assert root
    refute Map.has_key?(root, "parentSpanId")
    assert attr_value(root, "langfuse.session.id") == "telegram:555"
    assert attr_value(root, "session.id") == "telegram:555"
    assert attr_value(root, "langfuse.observation.input") == "what's the weather"
    assert attr_value(root, "langfuse.observation.output") == "It's sunny and 22C."
    assert attr_value(root, "gen_ai.completion") == "It's sunny and 22C."
    assert root["status"]["code"] == 1

    tool_span = Enum.find(spans, &(&1["name"] == "web_search"))
    assert tool_span["parentSpanId"] == root["spanId"]
    assert attr_value(tool_span, "langfuse.observation.type") == "span"
    assert attr_value(tool_span, "langfuse.observation.input") == "weather today"
    assert attr_value(tool_span, "langfuse.observation.output") == "sunny, 22C"

    gen_span = Enum.find(spans, &(&1["name"] == "gpt-4o"))
    assert gen_span["parentSpanId"] == root["spanId"]
    assert attr_value(gen_span, "langfuse.observation.type") == "generation"
    assert attr_value(gen_span, "gen_ai.request.model") == "gpt-4o"
    assert attr_value(gen_span, "langfuse.observation.model.name") == "gpt-4o"
    # int64 AnyValue fields are decimal STRINGS per the OTLP JSON spec (avoids
    # precision loss past JS's 53-bit safe integer range), not JSON numbers.
    assert attr_value(gen_span, "gen_ai.usage.input_tokens") == "120"
    assert attr_value(gen_span, "gen_ai.usage.output_tokens") == "40"

    # Every span shares one trace id, and it's derived from Pepe's own trace id (stable
    # across a hypothetical re-export), not random per call.
    trace_ids = Enum.map(spans, & &1["traceId"]) |> Enum.uniq()
    assert trace_ids == [root["traceId"]]
  end

  test "export/1 re-derives the same OTEL trace id for the same Pepe trace id (no duplicate/orphaned traces on retry)", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(sample_row())
    assert_receive {:otel_request, _, %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span1 | _]}]}]}}, 2000

    Otel.export(sample_row())
    assert_receive {:otel_request, _, %{"resourceSpans" => [%{"scopeSpans" => [%{"spans" => [span2 | _]}]}]}}, 2000

    assert span1["traceId"] == span2["traceId"]
  end

  test "OTEL_EXPORTER_OTLP_HEADERS is parsed and sent as literal request headers", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")
    System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Basic cGstbGY6c2stbGY=, x-langfuse-ingestion-version=4")

    Otel.export(sample_row())
    assert_receive {:otel_request, headers, _body}, 2000

    assert {"authorization", "Basic cGstbGY6c2stbGY="} in headers
    assert {"x-langfuse-ingestion-version", "4"} in headers
  end

  test "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is used as-is, with no /v1/traces appended", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:1")
    System.put_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://localhost:#{port}/custom/path")

    Otel.export(sample_row())
    assert_receive {:otel_request, _headers, _body}, 2000
  end

  test "a run with no session and no reply still exports a valid root span", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    row = %{id: "t2", agent: "assistant", session: nil, prompt: "hi", at: 1_700_000_000, ms: 5, outcome: %{"kind" => "ok"}, events: []}
    Otel.export(row)

    assert_receive {:otel_request, _, body}, 2000
    [%{"scopeSpans" => [%{"spans" => [root]}]}] = body["resourceSpans"]
    assert root["name"] == "pepe.run"
    refute Enum.any?(root["attributes"], &(&1["key"] == "langfuse.session.id"))
  end

  defp attr_value(span, key) do
    Enum.find_value(span["attributes"], fn
      %{"key" => ^key, "value" => %{"stringValue" => v}} -> v
      %{"key" => ^key, "value" => %{"intValue" => v}} -> v
      %{"key" => ^key, "value" => %{"boolValue" => v}} -> v
      _ -> nil
    end)
  end
end
