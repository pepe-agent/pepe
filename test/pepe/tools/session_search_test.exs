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

  defp ctx(agent_name \\ "assistant"), do: %{agent: %Agent{name: agent_name}}

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
end
