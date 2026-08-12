defmodule Pepe.OtelTest do
  # async: false - System.put_env/2 (OTEL_EXPORTER_OTLP_*) is process-wide, and the
  # mock collector registers a fixed process name.
  use ExUnit.Case, async: false

  alias Pepe.Otel

  @env_vars ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
               LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LANGFUSE_BASE_URL)

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_otel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockOtelCollector, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    prev = for k <- @env_vars, do: {k, System.get_env(k)}
    # A dev shell may have LANGFUSE_* set for the managed-prompts feature (see
    # Pepe.Langfuse) or its own local Langfuse trace export - clear it here so every
    # test starts from a deterministic "nothing configured" slate regardless of what's
    # ambient, same reasoning as clearing the OTEL_* vars above.
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev_home, do: System.put_env("PEPE_HOME", prev_home), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)

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

  test "enabled?/0 is true from LANGFUSE_PUBLIC_KEY/LANGFUSE_SECRET_KEY alone, no OTEL_* vars needed" do
    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
    assert Otel.enabled?()
  end

  test "enabled?/0 stays false with only one half of the Langfuse pair" do
    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    refute Otel.enabled?()
  end

  test "export/1 derives the Langfuse OTLP endpoint and Basic-auth header from LANGFUSE_* alone", %{port: port} do
    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
    System.put_env("LANGFUSE_BASE_URL", "http://localhost:#{port}")

    Otel.export(sample_row())
    assert_receive {:otel_request, headers, _body}, 2000

    assert {"authorization", "Basic " <> Base.encode64("pk-lf-test:sk-lf-test")} in headers
  end

  test "an explicit OTEL_EXPORTER_OTLP_ENDPOINT wins over LANGFUSE_* when both are set", %{port: port} do
    System.put_env("LANGFUSE_PUBLIC_KEY", "pk-lf-test")
    System.put_env("LANGFUSE_SECRET_KEY", "sk-lf-test")
    System.put_env("LANGFUSE_BASE_URL", "http://localhost:1")
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(sample_row())
    # Reaching the mock collector at all proves the explicit endpoint was used, not the
    # unreachable Langfuse one derived from LANGFUSE_BASE_URL above.
    assert_receive {:otel_request, headers, _body}, 2000
    # No Authorization header either - the explicit (empty) OTEL_EXPORTER_OTLP_HEADERS
    # path is used as-is, not silently backfilled from the Langfuse credentials.
    refute Enum.any?(headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
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

  test "a generation span carries user, release, channel and level attributes", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(sample_row())
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    root = Enum.find(spans, &(&1["name"] == "pepe.run"))

    assert attr_value(root, "langfuse.user.id") == "telegram:555"
    assert attr_value(root, "user.id") == "telegram:555"
    assert attr_value(root, "langfuse.release") == Pepe.Update.current()
    assert attr_value(root, "langfuse.trace.metadata.channel") == "telegram"
    assert attr_value(root, "langfuse.observation.level") == "DEFAULT"
  end

  test "an errored run's root span is marked at ERROR level, an unclassified one at WARNING", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(%{sample_row() | outcome: %{"kind" => "error", "reason" => "boom"}})
    assert_receive {:otel_request, _, body1}, 2000
    [%{"scopeSpans" => [%{"spans" => spans1}]}] = body1["resourceSpans"]
    assert attr_value(Enum.find(spans1, &(&1["name"] == "pepe.run")), "langfuse.observation.level") == "ERROR"

    Otel.export(%{sample_row() | id: "trace124", outcome: %{"kind" => "unknown"}})
    assert_receive {:otel_request, _, body2}, 2000
    [%{"scopeSpans" => [%{"spans" => spans2}]}] = body2["resourceSpans"]
    assert attr_value(Enum.find(spans2, &(&1["name"] == "pepe.run")), "langfuse.observation.level") == "WARNING"
  end

  test "a run with no session has no user attributes either", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    row = %{id: "t2", agent: "assistant", session: nil, prompt: "hi", at: 1_700_000_000, ms: 5, outcome: %{"kind" => "ok"}, events: []}
    Otel.export(row)

    assert_receive {:otel_request, _, body}, 2000
    [%{"scopeSpans" => [%{"spans" => [root]}]}] = body["resourceSpans"]
    refute Enum.any?(root["attributes"], &(&1["key"] == "langfuse.user.id"))
    refute Enum.any?(root["attributes"], &(&1["key"] == "user.id"))
  end

  test "child spans use each event's real recorded offset, not an even split of the run's total time", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    row = %{
      sample_row()
      | ms: 1000,
        events: [
          %{"t" => "tool_call", "name" => "web_search", "args" => "weather today", "ms" => 0},
          # A slow tool: 900ms between its call and its result, out of the run's 1000ms total.
          %{"t" => "tool_result", "name" => "web_search", "out" => "sunny, 22C", "ms" => 900},
          %{"t" => "usage", "model" => "gpt-4o", "in" => 120, "out" => 40, "ms" => 950},
          %{"t" => "assistant", "text" => "It's sunny and 22C.", "ms" => 1000}
        ]
    }

    Otel.export(row)
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    tool_span = Enum.find(spans, &(&1["name"] == "web_search"))
    gen_span = Enum.find(spans, &(&1["name"] == "gpt-4o"))

    tool_ns = String.to_integer(tool_span["endTimeUnixNano"]) - String.to_integer(tool_span["startTimeUnixNano"])
    gen_ns = String.to_integer(gen_span["endTimeUnixNano"]) - String.to_integer(gen_span["startTimeUnixNano"])

    # 900ms vs 50ms - nowhere near the same, unlike an even split across 4 events (250ms each).
    assert tool_ns == 900_000_000
    assert gen_ns == 50_000_000
  end

  test "child spans fall back to an even split for a trace row recorded before events carried a timestamp", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(sample_row())
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    durations = for s <- spans, s["name"] != "pepe.run", do: String.to_integer(s["endTimeUnixNano"]) - String.to_integer(s["startTimeUnixNano"])

    # sample_row's 4 events split the 1200ms run into 300ms windows each; only the
    # tool_call and usage events produce their own span (tool_result/assistant don't).
    assert [_, _] = durations
    assert Enum.uniq(durations) == [300_000_000]
  end

  test "langfuse.user.id/user.id prefer the sender's display name over the session key when given", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(Map.put(sample_row(), :sender, "Maria"))
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    root = Enum.find(spans, &(&1["name"] == "pepe.run"))

    assert attr_value(root, "langfuse.user.id") == "Maria"
    assert attr_value(root, "user.id") == "Maria"
    # The session id itself is untouched - it's still the real grouping key, not the name.
    assert attr_value(root, "langfuse.session.id") == "telegram:555"
  end

  test "langfuse.user.id falls back to the session key when there is no sender name", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")

    Otel.export(sample_row())
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    root = Enum.find(spans, &(&1["name"] == "pepe.run"))
    assert attr_value(root, "langfuse.user.id") == "telegram:555"
  end

  test "a generation span reports cost only when the model has a known price", %{port: port} do
    Pepe.Config.put_model(%Pepe.Config.Model{name: "gpt-4o", model: "gpt-4o", input_price: 2.5, output_price: 10.0})

    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")
    Otel.export(sample_row())
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    generation = Enum.find(spans, &(&1["name"] == "gpt-4o"))
    # 120 input tokens @ $2.50/1M + 40 output tokens @ $10/1M
    expected = 120 / 1_000_000 * 2.5 + 40 / 1_000_000 * 10.0
    assert_in_delta attr_value(generation, "gen_ai.usage.cost"), expected, 0.0000001
  end

  test "no cost attribute at all for a model with no known price", %{port: port} do
    System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:#{port}")
    row = put_in(sample_row(), [:events, Access.at(2), "model"], "totally-unknown-model-#{System.unique_integer([:positive])}")
    Otel.export(row)
    assert_receive {:otel_request, _, body}, 2000

    [%{"scopeSpans" => [%{"spans" => spans}]}] = body["resourceSpans"]
    generation = Enum.find(spans, &(&1["name"] =~ "unknown-model"))
    refute Enum.any?(generation["attributes"], &(&1["key"] == "gen_ai.usage.cost"))
  end

  defp attr_value(span, key) do
    Enum.find_value(span["attributes"], fn
      %{"key" => ^key, "value" => %{"stringValue" => v}} -> v
      %{"key" => ^key, "value" => %{"intValue" => v}} -> v
      %{"key" => ^key, "value" => %{"doubleValue" => v}} -> v
      %{"key" => ^key, "value" => %{"boolValue" => v}} -> v
      _ -> nil
    end)
  end
end
