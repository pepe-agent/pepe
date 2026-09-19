defmodule Pepe.Agent.SessionRewindTest do
  @moduledoc """
  `/rewind N`: dropping the last N exchanges of a live conversation and carrying on from
  before them. The three things that decide whether it is usable by a real person typing
  into a chat window: that it takes off exactly the turns they counted, that asking to go
  back further than the conversation reaches rewinds what there is and says so instead of
  refusing, and that a history already condensed by compaction comes out of it truthful.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.MicroCompaction
  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      if last["role"] != "tool" and to_string(last["content"]) =~ "USE_TOOL",
        do: reply(conn, nil, bash_call()),
        else: reply(conn, "sure thing", nil)
    end

    defp bash_call do
      [%{"id" => "call_1", "type" => "function", "function" => %{"name" => "bash", "arguments" => ~s({"command":"rm -rf /tmp/x"})}}]
    end

    defp reply(conn, content, tool_calls) do
      message =
        %{"role" => "assistant", "content" => content}
        |> then(fn m -> if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m end)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => if(tool_calls, do: "tool_calls", else: "stop")}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rewind_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "test", model: "mock-model"})

    Config.put_agent(%Pepe.Config.Agent{
      name: "helper",
      model: "mock",
      system_prompt: "You are the helper.",
      tools: ["bash"],
      max_iterations: 3
    })

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    key = "test:rewind:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "helper")
    {:ok, key: key}
  end

  defp allow, do: fn _name, _args, _ctx -> :once end

  defp ask(key, text), do: {:ok, _} = Session.chat(key, text, learn: false, authorize: allow())

  defp said?(key, text), do: Enum.any?(Session.history(key), &(to_string(&1["content"]) =~ text))

  describe "rewinding by a count" do
    test "drops exactly the last N exchanges and keeps everything before them", %{key: key} do
      ask(key, "question one")
      after_first = Session.history(key)
      ask(key, "question two")
      ask(key, "question three")

      assert Session.rewind(key, 2) == {:ok, 2}

      # Back to precisely where the conversation stood after the first exchange - the two
      # later questions and their answers are gone, the first one is untouched.
      assert Session.history(key) == after_first
      assert said?(key, "question one")
      refute said?(key, "question two")
      refute said?(key, "question three")
    end

    test "a bare rewind of one turn matches what /undo does", %{key: key} do
      ask(key, "question one")
      after_first = Session.history(key)
      ask(key, "question two")

      assert Session.rewind(key) == {:ok, 1}
      assert Session.history(key) == after_first
    end

    test "the conversation carries on from the rewound point", %{key: key} do
      ask(key, "question one")
      ask(key, "a wrong turn")
      assert Session.rewind(key, 1) == {:ok, 1}

      ask(key, "a better question")

      # The bad path is not merely hidden: it never reaches the model again.
      refute said?(key, "a wrong turn")
      assert said?(key, "a better question")
      assert Session.status(key).turns == 2
    end
  end

  describe "asking for more than there is" do
    test "rewinds everything available and reports the smaller number", %{key: key} do
      ask(key, "question one")
      ask(key, "question two")

      # Refusing here would leave a person guessing which N is small enough, on a surface
      # with nothing to count against but their own scrollback.
      assert Session.rewind(key, 50) == {:ok, 2}
      assert Session.status(key).turns == 0

      # The agent's persona survives; only the conversation went.
      assert [%{"role" => "system", "content" => prompt}] = Session.history(key)
      assert prompt =~ "You are the helper."
    end

    test "says nothing went rather than failing when there is nothing to rewind", %{key: key} do
      before = Session.history(key)

      assert Session.rewind(key, 3) == {:ok, 0}
      assert Session.history(key) == before
    end
  end

  describe "while a turn is in flight" do
    test "is refused rather than silently reverted when the turn lands", %{key: key} do
      ask(key, "question one")
      test_pid = self()

      gate = fn _name, _args, _ctx ->
        send(test_pid, :at_gate)
        receive do: (:release -> :once)
      end

      caller = Task.async(fn -> Session.chat(key, "USE_TOOL", learn: false, authorize: gate) end)
      assert_receive :at_gate, 5_000

      # The running turn finishes by writing its own history back, which would undo the
      # rewind without a word. Saying "busy" is the only honest answer.
      assert Session.rewind(key, 1) == {:error, :busy}

      assert Session.stop(key) == :ok
      assert Task.await(caller) == {:error, :stopped}
      assert said?(key, "question one")
    end
  end

  describe "a count that is not a number of turns" do
    test "is rejected before it reaches the session", %{key: _key} do
      assert Session.parse_rewind_count("") == {:ok, 1}
      assert Session.parse_rewind_count("  3 ") == {:ok, 3}

      assert Session.parse_rewind_count("0") == :error
      assert Session.parse_rewind_count("-2") == :error
      assert Session.parse_rewind_count("two") == :error
      assert Session.parse_rewind_count("2 turns") == :error
    end

    test "a non-positive count reaching the session is a no-op, not a crash", %{key: key} do
      ask(key, "question one")
      before = Session.history(key)

      assert Session.rewind(key, 0) == {:ok, 0}
      assert Session.rewind(key, -5) == {:ok, 0}
      assert Session.history(key) == before
    end
  end

  describe "with a compacted history" do
    # What /compact leaves behind: the system prompt, one summary standing in for the turns
    # it condensed away, and the recent turns kept verbatim. The summary wears the `user`
    # role (several providers drop every system message after the first), which is exactly
    # what a naive "count the user messages" rewind would miscount.
    defp compacted_history do
      [
        Message.system("You are the helper."),
        Message.user("<system-reminder>\nSummary of the earlier conversation: we chose the blue plan.\n</system-reminder>"),
        Message.user("recent question one"),
        Message.assistant("recent answer one"),
        Message.user("recent question two"),
        Message.assistant("recent answer two")
      ]
    end

    test "the summary is not counted as a turn", %{key: key} do
      :ok = Session.seed(key, %{messages: compacted_history(), model_override: nil, pii_map: []})

      assert Session.rewind(key, 1) == {:ok, 1}

      # One turn asked for, one real turn gone - not the summary standing in front of it.
      assert said?(key, "recent question one")
      refute said?(key, "recent question two")
      assert said?(key, "we chose the blue plan")
    end

    test "rewinding past every live turn keeps the summary of what compaction already discarded", %{key: key} do
      :ok = Session.seed(key, %{messages: compacted_history(), model_override: nil, pii_map: []})

      assert Session.rewind(key, 10) == {:ok, 2}

      # The summarized turns are not recoverable by any rewind - compaction already threw
      # them out - so dropping their summary would lose context without undoing anything.
      # What remains describes only conversation older than everything just rewound.
      assert [%{"role" => "system"}, %{"role" => "user", "content" => summary}] = Session.history(key)
      assert summary =~ "we chose the blue plan"
      refute said?(key, "recent question one")
      refute said?(key, "recent question two")
    end

    test "the running micro-compaction summary is dropped, so it can't describe rewound turns", %{key: key} do
      ask(key, "question one")
      ask(key, "question two")

      # As a turn near the context window would have left it: a running summary plus how
      # many exchanges of THIS message list it already folded in.
      MicroCompaction.put(key, "so far: the user asked two questions", 2)

      assert Session.rewind(key, 1) == {:ok, 1}

      # Keeping it would carry a summary of a conversation that no longer happened into
      # the next turn, indexed against a message list that just got shorter. Re-folding
      # from scratch is what this cache is designed to survive.
      assert MicroCompaction.get(key) == nil
    end

    test "a rewind that drops nothing leaves the running summary alone", %{key: key} do
      MicroCompaction.put(key, "so far: nothing much", 1)

      assert Session.rewind(key, 2) == {:ok, 0}

      # Nothing changed, so there is nothing for the cache to be wrong about - paying for a
      # re-fold here would be a cost with no correctness behind it.
      assert MicroCompaction.get(key) == {"so far: nothing much", 1}
    end
  end
end
