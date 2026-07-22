defmodule Pepe.Tools.SessionSearchTest do
  @moduledoc """
  `session_search` - find/read past conversations, built entirely on `Pepe.Trace`
  (see its own moduledoc for why: a session's live process holds only the current
  conversation, traces are what outlives it).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config.Agent
  alias Pepe.Tools.SessionSearch
  alias Pepe.Trace

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_session_search_#{System.unique_integer([:positive])}")
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

  # These tests cover search/list/history mechanics, not the self/project scope boundary
  # (see the "session_search_scope" describe block below for that) - explicitly opted
  # into "project" scope so a trace with no session key (a one-shot run) or a different
  # session key than the caller's own still shows up, matching what they each assert.
  defp ctx(agent_name \\ "assistant"), do: %{agent: %Agent{name: agent_name, session_search_scope: "project"}}

  test "refuses without a calling agent in context" do
    assert SessionSearch.run(%{"action" => "list_sessions"}, %{}) == {:error, "no calling agent in context"}
  end

  test "refuses without an action" do
    assert SessionSearch.run(%{}, ctx()) == {:error, "session_search needs an `action`"}
  end

  test "list_sessions: empty, then lists a real one with its turn count" do
    assert SessionSearch.run(%{"action" => "list_sessions"}, ctx()) == {:ok, "No conversations recorded yet."}

    Trace.start("assistant", "telegram:1")
    Trace.finish({:ok, "a", []})
    Trace.start("assistant", "telegram:1")
    Trace.finish({:ok, "b", []})

    {:ok, out} = SessionSearch.run(%{"action" => "list_sessions"}, ctx())
    assert out =~ "telegram:1"
    assert out =~ "2 turns"
  end

  test "search: finds a matching prompt, reports no matches otherwise" do
    Trace.start("assistant", nil, "reconcile the may invoices")
    Trace.finish({:ok, "done", []})

    {:ok, out} = SessionSearch.run(%{"action" => "search", "query" => "invoices"}, ctx())
    assert out =~ "reconcile"

    assert SessionSearch.run(%{"action" => "search", "query" => "nothing like this"}, ctx()) ==
             {:ok, "No matches for \"nothing like this\"."}
  end

  test "search: needs a query" do
    assert SessionSearch.run(%{"action" => "search"}, ctx()) == {:error, "session_search needs `query`"}
  end

  test "session_history: every turn for one session key, in order" do
    Trace.start("assistant", "telegram:9", "first")
    Trace.finish({:ok, "a", []})
    Trace.start("assistant", "telegram:9", "second")
    Trace.finish({:ok, "b", []})

    {:ok, out} = SessionSearch.run(%{"action" => "session_history", "session" => "telegram:9"}, ctx())
    first_at = :binary.match(out, "first") |> elem(0)
    second_at = :binary.match(out, "second") |> elem(0)
    assert first_at < second_at
  end

  test "session_history: needs a session key" do
    assert SessionSearch.run(%{"action" => "session_history"}, ctx()) == {:error, "session_search needs `session`"}
  end

  test "show: the full transcript of one trace by id" do
    Trace.start("assistant", nil, "check disk space")
    Trace.event({:tool_call, "bash", ~s({"command":"df -h"})})
    Trace.event({:tool_result, "bash", "12% used"})
    id = Trace.finish({:ok, "12% used, fine", []})

    {:ok, out} = SessionSearch.run(%{"action" => "show", "trace_id" => id}, ctx())
    assert out =~ "check disk space"
    assert out =~ "bash"
    assert out =~ "df -h"
    assert out =~ "12% used"
  end

  test "show: an unknown trace id is a clean error" do
    assert SessionSearch.run(%{"action" => "show", "trace_id" => "ghost"}, ctx()) == {:error, "no such trace: ghost"}
  end

  test "an unknown action is a clean error" do
    assert SessionSearch.run(%{"action" => "delete_everything"}, ctx()) == {:error, "unknown action: delete_everything"}
  end

  test "is scoped to the calling agent's own project, not another one's" do
    Trace.start("acme/bot", nil, "acme's own thing")
    Trace.finish({:ok, "done", []})

    {:ok, out} = SessionSearch.run(%{"action" => "search", "query" => "own thing"}, ctx("globex/bot"))
    assert out =~ "No matches"
  end

  describe "session_search_scope (an agent talking to several different end customers must not leak across them)" do
    defp self_ctx(session_key), do: %{agent: %Agent{name: "assistant"}, session_key: session_key}

    test "the default (\"self\") is the Agent struct's own default, not something a caller has to opt into" do
      assert %Agent{}.session_search_scope == "self"
    end

    test "list_sessions only shows the caller's own session, not another customer's, by default" do
      Trace.start("assistant", "telegram:me")
      Trace.finish({:ok, "a", []})
      Trace.start("assistant", "telegram:someone-else")
      Trace.finish({:ok, "b", []})

      {:ok, out} = SessionSearch.run(%{"action" => "list_sessions"}, self_ctx("telegram:me"))
      assert out =~ "telegram:me"
      refute out =~ "telegram:someone-else"
    end

    test "search only matches the caller's own session's content, not another customer's" do
      Trace.start("assistant", "telegram:me", "my own invoice question")
      Trace.finish({:ok, "done", []})
      Trace.start("assistant", "telegram:someone-else", "someone else's invoice question")
      Trace.finish({:ok, "done", []})

      {:ok, out} = SessionSearch.run(%{"action" => "search", "query" => "invoice"}, self_ctx("telegram:me"))
      assert out =~ "my own invoice question"
      refute out =~ "someone else's invoice question"
    end

    test "session_history refuses another customer's session key, reporting it the same as empty" do
      Trace.start("assistant", "telegram:someone-else", "private stuff")
      Trace.finish({:ok, "done", []})

      assert SessionSearch.run(%{"action" => "session_history", "session" => "telegram:someone-else"}, self_ctx("telegram:me")) ==
               {:ok, "No turns recorded for telegram:someone-else."}
    end

    test "session_history still works for the caller's own session key" do
      Trace.start("assistant", "telegram:me", "first")
      Trace.finish({:ok, "a", []})

      {:ok, out} = SessionSearch.run(%{"action" => "session_history", "session" => "telegram:me"}, self_ctx("telegram:me"))
      assert out =~ "first"
    end

    test "show refuses a trace_id belonging to another customer's session" do
      Trace.start("assistant", "telegram:someone-else", "private stuff")
      id = Trace.finish({:ok, "done", []})

      assert SessionSearch.run(%{"action" => "show", "trace_id" => id}, self_ctx("telegram:me")) ==
               {:error, "no such trace: #{id}"}
    end

    test "show still works for a trace_id belonging to the caller's own session" do
      Trace.start("assistant", "telegram:me", "my own thing")
      id = Trace.finish({:ok, "done", []})

      {:ok, out} = SessionSearch.run(%{"action" => "show", "trace_id" => id}, self_ctx("telegram:me"))
      assert out =~ "my own thing"
    end

    test "with no session key in ctx at all (a one-shot run), self scope sees nothing rather than falling open" do
      Trace.start("assistant", "telegram:someone-else")
      Trace.finish({:ok, "done", []})

      assert SessionSearch.run(%{"action" => "list_sessions"}, %{agent: %Agent{name: "assistant"}}) ==
               {:ok, "No conversations recorded yet."}
    end

    test "an agent explicitly opted into \"project\" scope keeps the old, full-project visibility" do
      Trace.start("assistant", "telegram:someone-else", "widened on purpose")
      Trace.finish({:ok, "done", []})

      wide_ctx = %{agent: %Agent{name: "assistant", session_search_scope: "project"}, session_key: "telegram:me"}
      {:ok, out} = SessionSearch.run(%{"action" => "search", "query" => "widened"}, wide_ctx)
      assert out =~ "widened on purpose"
    end
  end
end
