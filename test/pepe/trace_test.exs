defmodule Pepe.TraceTest do
  use ExUnit.Case, async: false

  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_trace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    :ok
  end

  test "start/event/finish record a run and it reads back with its events" do
    assert Trace.start("acme/bot", "api:123") == :started
    Trace.event({:tool_call, "read_file", ~s({"path":"a.txt"})})
    Trace.event({:tool_result, "read_file", "hello"})
    Trace.event({:assistant, "done"})
    id = Trace.finish({:ok, "done", []})

    assert is_binary(id)

    [summary] = Trace.recent("acme")
    assert summary["agent"] == "acme/bot"
    assert summary["session"] == "api:123"
    # source is derived from the session key's first segment when not given explicitly
    assert summary["source"] == "api"
    assert summary["outcome"]["kind"] == "ok"
    assert summary["tools"] == ["read_file"]
    refute Map.has_key?(summary, "events")

    full = Trace.get("acme", id)
    kinds = Enum.map(full["events"], & &1["t"])
    assert kinds == ["tool_call", "tool_result", "assistant"]
  end

  test "an error outcome is captured" do
    assert Trace.start("bot", nil) == :started
    Trace.finish({:error, :budget_exceeded})

    [summary] = Trace.recent("root")
    assert summary["outcome"]["kind"] == "error"
    assert summary["outcome"]["reason"] =~ "budget_exceeded"
  end

  test "the summary carries compact per-model token usage" do
    assert Trace.start("bot", nil) == :started
    Trace.event({:usage, "gpt", %{prompt_tokens: 100, completion_tokens: 40}})
    Trace.event({:usage, "gpt", %{prompt_tokens: 10, completion_tokens: 5}})
    Trace.finish({:ok, "done", []})

    [summary] = Trace.recent("root")
    assert summary["usage"] == [%{"model" => "gpt", "in" => 100, "out" => 40}, %{"model" => "gpt", "in" => 10, "out" => 5}]
    refute Map.has_key?(summary, "events")
  end

  test "usage accepts the Responses-API token key names" do
    assert Trace.start("bot", nil) == :started
    Trace.event({:usage, "gpt", %{"input_tokens" => 80, "output_tokens" => 20}})
    Trace.finish({:ok, "x", []})

    [s] = Trace.recent("root")
    assert s["usage"] == [%{"model" => "gpt", "in" => 80, "out" => 20}]
  end

  test "an explicit source overrides the session-derived one" do
    assert Trace.start("bot", nil, "housekeeping", "cron") == :started
    Trace.finish({:ok, "done", []})

    [summary] = Trace.recent("root")
    assert summary["source"] == "cron"
  end

  test "source_from_session reads the surface off the session key" do
    assert Trace.source_from_session("telegram:42") == "telegram"
    assert Trace.source_from_session("telegram:sales:42") == "telegram"
    assert Trace.source_from_session("chatwoot:assistant:c1") == "chatwoot"
    assert Trace.source_from_session(nil) == "manual"
  end

  test "a nested run folds its events into the outer trace, not a second one" do
    assert Trace.start("acme/bot", nil) == :started
    Trace.event({:tool_call, "send_to_agent", "{}"})
    # sub-agent run in the same process: :nested, so its run/3 never calls finish
    assert Trace.start("acme/helper", nil) == :nested
    Trace.event({:tool_call, "bash", "{}"})
    # only the outer run finishes, and it holds both tool calls
    id = Trace.finish({:ok, "outer", []})

    full = Trace.get("acme", id)
    names = for %{"t" => "tool_call", "name" => n} <- full["events"], do: n
    assert names == ["send_to_agent", "bash"]
    assert length(Trace.recent("acme")) == 1
  end

  test "streaming deltas are dropped from the trace" do
    Trace.start("bot", nil)
    Trace.event({:assistant_delta, "he"})
    Trace.event({:assistant_delta, "llo"})
    Trace.event({:assistant, "hello"})
    id = Trace.finish({:ok, "hello", []})

    kinds = Trace.get("root", id)["events"] |> Enum.map(& &1["t"])
    assert kinds == ["assistant"]
  end
end
