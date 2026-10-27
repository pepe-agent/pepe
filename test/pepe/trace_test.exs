defmodule Pepe.TraceTest do
  use ExUnit.Case, async: false

  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_trace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
      Process.delete(:pepe_trace)
    end)

    :ok
  end

  describe "run details" do
    test "a run event records the model setup and survives clipping accented text" do
      Trace.start("bot", nil, "oi")
      Trace.event({:run, %{"model" => "openai", "host" => "api.openai.com", "tools" => 3}})
      # Longer than the clip limit, with a multi-byte character straddling the cut.
      Trace.event({:tool_result, "bash", String.duplicate("a", 3_999) <> String.duplicate("ã", 10)})
      id = Trace.finish({:ok, "ok", []})
      scope = Pepe.Config.default_project_slug()

      assert %{"events" => [run, result]} = Trace.get(scope, id)
      assert %{"t" => "run", "model" => "openai", "host" => "api.openai.com", "tools" => 3} = run
      assert String.valid?(result["out"])
    end
  end

  describe "a run in progress" do
    test "shows up as running with its first events before it finishes" do
      assert Trace.start("acme/bot", "api:123", "check the logs") == :started
      scope = Pepe.Project.of("acme/bot") |> then(&(&1 || Pepe.Config.default_project_slug()))

      assert [%{"outcome" => %{"kind" => "running"}, "prompt" => "check the logs"}] = Trace.recent(scope)

      Trace.event({:tool_call, "read_file", ~s({"path":"a.txt"})})
      [%{"id" => id}] = Trace.recent(scope)
      assert %{"outcome" => %{"kind" => "running"}, "events" => [%{"t" => "tool_call"}]} = Trace.get(scope, id)
    end

    test "finish replaces the running row instead of adding a second one" do
      Trace.start("acme/bot", "api:123", "hi")
      scope = Pepe.Project.of("acme/bot") |> then(&(&1 || Pepe.Config.default_project_slug()))
      [%{"id" => running_id}] = Trace.recent(scope)

      assert Trace.finish({:ok, "done", []}) == running_id
      assert [%{"id" => ^running_id, "outcome" => %{"kind" => "ok"}}] = Trace.recent(scope)
    end

    test "a run whose process died before finishing reads back as interrupted" do
      parent = self()

      pid =
        spawn(fn ->
          Trace.start("acme/bot", "api:9", "never finishes")
          send(parent, {:started, Trace.current().id})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, id}
      scope = Pepe.Project.of("acme/bot") |> then(&(&1 || Pepe.Config.default_project_slug()))
      assert %{"outcome" => %{"kind" => "running"}} = Trace.get(scope, id)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert %{"outcome" => %{"kind" => "interrupted"}} = eventually(fn -> Trace.get(scope, id) end, "interrupted")
    end
  end

  # The registry drops a dead process's entry asynchronously, so poll briefly.
  defp eventually(fun, kind, tries \\ 40) do
    result = fun.()

    cond do
      get_in(result, ["outcome", "kind"]) == kind ->
        result

      tries == 0 ->
        result

      true ->
        Process.sleep(25)
        eventually(fun, kind, tries - 1)
    end
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

  test "tool_denied carries the reason (or nil) through to the stored event" do
    assert Trace.start("acme/bot", "api:456") == :started
    Trace.event({:tool_denied, "bash", "too risky"})
    Trace.event({:tool_denied, "write_file", nil})
    id = Trace.finish({:ok, "done", []})

    full = Trace.get("acme", id)
    denied = full["events"] |> Enum.filter(&(&1["t"] == "tool_denied")) |> Enum.map(&Map.drop(&1, ["ms"]))

    assert %{"t" => "tool_denied", "name" => "bash", "reason" => "too risky"} in denied
    assert %{"t" => "tool_denied", "name" => "write_file", "reason" => nil} in denied
  end

  test "an error outcome is captured" do
    assert Trace.start("bot", nil) == :started
    Trace.finish({:error, :budget_exceeded})

    [summary] = Trace.recent("default")
    assert summary["outcome"]["kind"] == "error"
    assert summary["outcome"]["reason"] =~ "budget_exceeded"
  end

  test "the summary carries compact per-model token usage" do
    assert Trace.start("bot", nil) == :started
    Trace.event({:usage, "gpt", %{prompt_tokens: 100, completion_tokens: 40}})
    Trace.event({:usage, "gpt", %{prompt_tokens: 10, completion_tokens: 5}})
    Trace.finish({:ok, "done", []})

    [summary] = Trace.recent("default")
    assert summary["usage"] == [%{"model" => "gpt", "in" => 100, "out" => 40}, %{"model" => "gpt", "in" => 10, "out" => 5}]
    refute Map.has_key?(summary, "events")
  end

  test "usage accepts the Responses-API token key names" do
    assert Trace.start("bot", nil) == :started
    Trace.event({:usage, "gpt", %{"input_tokens" => 80, "output_tokens" => 20}})
    Trace.finish({:ok, "x", []})

    [s] = Trace.recent("default")
    assert s["usage"] == [%{"model" => "gpt", "in" => 80, "out" => 20}]
  end

  test "an explicit source overrides the session-derived one" do
    assert Trace.start("bot", nil, "housekeeping", "cron") == :started
    Trace.finish({:ok, "done", []})

    [summary] = Trace.recent("default")
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
    assert match?([_], Trace.recent("acme"))
  end

  test "streaming deltas are dropped from the trace" do
    Trace.start("bot", nil)
    Trace.event({:assistant_delta, "he"})
    Trace.event({:assistant_delta, "llo"})
    Trace.event({:assistant, "hello"})
    id = Trace.finish({:ok, "hello", []})

    kinds = Trace.get("default", id)["events"] |> Enum.map(& &1["t"])
    assert kinds == ["assistant"]
  end

  describe "for_session/3, sessions/2, search/3" do
    test "for_session/3 returns only that session's turns, oldest first" do
      Trace.start("bot", "telegram:1", "first")
      Trace.finish({:ok, "a", []})
      Trace.start("bot", "telegram:2", "other session")
      Trace.finish({:ok, "b", []})
      Trace.start("bot", "telegram:1", "second")
      Trace.finish({:ok, "c", []})

      turns = Trace.for_session("default", "telegram:1")
      assert Enum.map(turns, & &1["prompt"]) == ["first", "second"]
    end

    test "sessions/2 lists distinct sessions with a turn count, most recently active first" do
      Trace.start("bot", "telegram:1")
      Trace.finish({:ok, "a", []})
      Trace.start("bot", "telegram:2")
      Trace.finish({:ok, "b", []})
      Trace.start("bot", "telegram:1")
      Trace.finish({:ok, "c", []})

      sessions = Trace.sessions("default")
      assert Enum.map(sessions, & &1["session"]) == ["telegram:1", "telegram:2"]
      assert Enum.find(sessions, &(&1["session"] == "telegram:1"))["turns"] == 2
    end

    test "sessions/2 excludes stateless runs (no session key at all)" do
      Trace.start("bot", nil)
      Trace.finish({:ok, "a", []})

      assert Trace.sessions("default") == []
    end

    test "search/3 matches the prompt, case-insensitively" do
      Trace.start("bot", nil, "check the invoice totals")
      Trace.finish({:ok, "done", []})
      Trace.start("bot", nil, "something unrelated")
      Trace.finish({:ok, "done", []})

      [match] = Trace.search("default", "INVOICE")
      assert match["prompt"] =~ "invoice"
    end

    test "search/3 matches tool-call arguments too, not just the prompt" do
      Trace.start("bot", nil, "do the thing")
      Trace.event({:tool_call, "read_file", ~s({"path":"budget-2026.csv"})})
      Trace.finish({:ok, "done", []})
      Trace.start("bot", nil, "do another thing")
      Trace.finish({:ok, "done", []})

      [match] = Trace.search("default", "budget-2026")
      assert match["prompt"] == "do the thing"
    end
  end
end
