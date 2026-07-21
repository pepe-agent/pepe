defmodule Pepe.Agent.SessionCommandsTest do
  @moduledoc """
  The session commands that edit or read a live conversation without being a plain
  turn: /undo, /agent, /status, /btw (aside), /learn and /compact - plus the two ways a
  turn can end badly (the model failing, the run task being killed from outside), which
  is where a session gets wedged if nobody is watching.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Answers a turn plainly, asks for `bash` when the user says USE_TOOL (which, paired
  # with an authorizer that never answers, parks the run inside the permission gate: a
  # reliable "still running" window), and fails outright in :fail mode.
  defmodule MockPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      last = body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

      cond do
        mode() == :fail -> fail(conn)
        last["role"] == "tool" -> reply(conn, "done", nil)
        to_string(last["content"]) =~ "USE_TOOL" -> reply(conn, nil, bash_call())
        true -> reply(conn, "sure thing", nil)
      end
    end

    # A background review can outlive the test that started it; reading a dead Agent
    # would answer it with a 500 and a retry storm in the next test's logs.
    defp mode do
      Agent.get(:session_cmd_mode, & &1)
    catch
      :exit, _ -> :ok
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

    # 400, not 5xx: it fails the turn just the same, and the client does not spend three
    # retries and seconds of backoff on it, which the suite would feel.
    defp fail(conn) do
      conn |> put_resp_content_type("application/json") |> send_resp(400, ~s({"error":"nope"}))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_sess_cmd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, _} = Agent.start_link(fn -> :ok end, name: :session_cmd_mode)
    {:ok, server} = Bandit.start_link(plug: MockPlug, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{
      name: "mock",
      base_url: "http://localhost:#{port}",
      api_key: "test",
      model: "mock-model",
      # Small enough that a handful of messages is already a long conversation, so
      # /compact has a middle to summarize without seeding a novel first.
      context_window: 200
    })

    Config.put_agent(%Pepe.Config.Agent{
      name: "helper",
      model: "mock",
      system_prompt: "You are the helper.",
      tools: ["bash"],
      max_iterations: 5
    })

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "test:cmd:#{System.unique_integer([:positive])}"}
  end

  defp fails, do: Agent.update(:session_cmd_mode, fn _ -> :fail end)

  defp allow, do: fn _name, _args, _ctx -> :once end

  # Parks the run inside the permission gate and says so first, so a test knows the turn
  # is really in flight instead of guessing at it with a sleep.
  defp gate(test_pid) do
    fn _name, _args, _ctx ->
      send(test_pid, {:at_gate, self()})
      receive do: (:release -> :once)
    end
  end

  # Hand the session a chat request straight from the TEST process. Messages from one
  # process reach a GenServer in send order, so it is guaranteed to be queued behind the
  # running turn; from a Task the two would race.
  defp queue_chat(pid, text, opts) do
    tag = make_ref()
    send(pid, {:"$gen_call", {self(), tag}, {:chat, text, opts}})
    tag
  end

  defp start!(key, agent \\ "helper") do
    {:ok, pid} = SessionSupervisor.ensure(key, agent)
    pid
  end

  describe "/undo" do
    test "drops the last exchange, leaving the one before it intact", %{key: key} do
      start!(key)

      {:ok, _} = Session.chat(key, "first question", authorize: allow())
      after_first = Session.history(key)
      {:ok, _} = Session.chat(key, "second question", authorize: allow())

      assert length(Session.history(key)) > length(after_first)

      assert Session.undo(key) == :ok
      assert Session.history(key) == after_first
      # The point of /undo: the second question is gone, so the next turn is answered as
      # if it had never been asked.
      refute Enum.any?(Session.history(key), &(&1["content"] =~ "second question"))
    end

    test "is a harmless no-op when there is nothing to undo", %{key: key} do
      start!(key)
      before = Session.history(key)

      assert Session.undo(key) == :ok
      assert Session.history(key) == before
    end
  end

  describe "/agent" do
    test "rebinds the session and reseeds the system prompt from the new agent", %{key: key} do
      Config.put_agent(%Pepe.Config.Agent{name: "sales", model: "mock", system_prompt: "You close deals.", max_iterations: 5})
      start!(key)

      {:ok, _} = Session.chat(key, "hello", authorize: allow())
      assert Session.status(key).agent == "default/helper"

      assert Session.set_agent(key, "sales") == :ok

      assert Session.status(key).agent == "sales"
      # A switch is a fresh start on the new persona, not the old one wearing a new name.
      assert [%{"role" => "system", "content" => prompt}] = Session.history(key)
      assert prompt =~ "You close deals."
    end
  end

  describe "/status" do
    test "reports the bound agent, the resolved model id and the turns taken", %{key: key} do
      start!(key)

      assert Session.status(key) == %{agent: "helper", model: "mock-model", turns: 0, running: false}

      {:ok, _} = Session.chat(key, "one", authorize: allow())
      {:ok, _} = Session.chat(key, "two", authorize: allow())

      assert Session.status(key).turns == 2
    end
  end

  describe "/btw (a side question)" do
    test "is answered from the live context but never recorded", %{key: key} do
      start!(key)
      {:ok, _} = Session.chat(key, "the real conversation", authorize: allow())
      before = Session.history(key)

      assert {:ok, reply} = Session.aside(key, "just wondering, unrelated")
      assert reply =~ "sure thing"

      # Neither the question nor its answer may influence any later turn - that is the
      # entire difference between /btw and just sending a message.
      assert Session.history(key) == before
    end

    test "surfaces a model failure instead of crashing the session", %{key: key} do
      pid = start!(key)
      fails()

      assert {:error, _reason} = Session.aside(key, "anything")

      # The session survived its own failure and still answers.
      assert Process.alive?(pid)
      assert Session.status(key).turns == 0
    end
  end

  describe "/learn" do
    test "is refused for a conversation that is not allowed to teach the agent", %{key: key} do
      start!(key)
      # How a customer-facing surface marks a client's chat: it must never become memory.
      {:ok, _} = Session.chat(key, "a client talking", learn: false, authorize: allow())

      assert Session.learn(key) == {:error, :not_allowed}
    end

    test "runs the review for a conversation that is allowed to", %{key: key} do
      start!(key)
      {:ok, _} = Session.chat(key, "the owner talking", learn: true, authorize: allow())

      assert Session.learn(key) == :ok
    end
  end

  describe "/compact" do
    # Seeded rather than chatted into existence: what /compact does to a long history is
    # the claim, and 20 real turns against a model would only make it slower and vaguer.
    defp long_history do
      [Message.system("You are the helper.")] ++
        Enum.flat_map(1..10, fn n ->
          [Message.user("question number #{n} about the thing"), Message.assistant("answer number #{n} about the thing")]
        end)
    end

    test "replaces the middle with a summary and keeps the recent tail verbatim", %{key: key} do
      pid = start!(key)
      # Learning off first, so the review /compact fires before summarizing (it wants the
      # full detail while it is still there) doesn't outlive the mock server.
      {:ok, _} = Session.chat(key, "warm up", learn: false, authorize: allow())
      :ok = Session.seed(key, %{messages: long_history(), model_override: nil, pii_map: []})

      assert {:ok, summary} = Session.compact(key)
      assert summary =~ "sure thing"

      compacted = Session.history(key)
      assert length(compacted) < length(long_history())

      # The head (system prompt) and the most recent turns survive untouched - a
      # compaction that dropped the last thing said would be worse than none.
      assert List.first(compacted)["role"] == "system"
      assert List.last(compacted)["content"] =~ "answer number 10"
      assert Enum.any?(compacted, &(&1["content"] =~ "sure thing"))
      # ...and the middle is gone.
      refute Enum.any?(compacted, &(&1["content"] =~ "question number 2 "))
      assert Process.alive?(pid)
    end

    test "reports the failure, and keeps the history, when the summarizing call fails", %{key: key} do
      start!(key)
      {:ok, _} = Session.chat(key, "warm up", learn: false, authorize: allow())
      :ok = Session.seed(key, %{messages: long_history(), model_override: nil, pii_map: []})
      fails()

      assert {:error, _reason} = Session.compact(key)
      # A compaction that failed must not eat the conversation it was condensing.
      assert Session.history(key) == long_history()
    end
  end

  describe "a turn that ends badly" do
    test "a heartbeat pulse is skipped while a turn is in flight, never collided with", %{key: key} do
      start!(key)
      blocking = gate(self())
      caller = Task.async(fn -> Session.chat(key, "USE_TOOL", authorize: blocking) end)
      assert_receive {:at_gate, _runner}

      assert Session.heartbeat(key) == {:error, :busy}

      assert Session.stop(key) == :ok
      assert Task.await(caller) == {:error, :stopped}
    end

    test "a run task killed from outside unblocks its caller and frees the session", %{key: key} do
      pid = start!(key)

      blocking = gate(self())
      caller = Task.async(fn -> Session.chat(key, "USE_TOOL", authorize: blocking) end)
      assert_receive {:at_gate, _runner}

      # The run task itself, not whatever process the gate happened to block in.
      %{running: %{task: task}} = :sys.get_state(pid)
      queued = queue_chat(pid, "sent while it was dying", authorize: allow())

      Process.exit(task, :kill)

      # Without the DOWN handler this caller would block until its call timed out and the
      # session would stay pinned on "busy" forever.
      assert Task.await(caller) == {:error, :stopped}
      assert_receive {^queued, {:ok, _reply}}, 5_000
      assert Session.stop(key) == {:error, :not_running}
    end

    test "a listener that crashes on an event never takes the conversation down with it", %{key: key} do
      pid = start!(key)

      boom = fn
        :committed -> raise "this listener is broken"
        _other -> :ok
      end

      assert {:ok, _} = Session.chat(key, "one", on_event: boom, authorize: allow())

      assert Process.alive?(pid)
      assert {:ok, _} = Session.chat(key, "two", on_event: boom, authorize: allow())
      assert Session.status(key).turns == 2
    end
  end

  test "an agent created after the chat window opened still gets its system prompt", %{key: key} do
    # The session starts bound to an agent that does not exist yet, so it has no system
    # message at all. Whoever creates the agent next must not end up with a personaless
    # conversation for the rest of its life.
    start!(key, "not-yet")
    assert Session.history(key) == []

    Config.put_agent(%Pepe.Config.Agent{name: "not-yet", model: "mock", system_prompt: "You arrived late.", max_iterations: 5})

    {:ok, _} = Session.chat(key, "hello", authorize: allow())

    assert [%{"role" => "system", "content" => prompt} | _] = Session.history(key)
    assert prompt =~ "You arrived late."
  end

  describe "with no agent configured at all" do
    setup do
      empty = Path.join(System.tmp_dir!(), "pepe_sess_empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", empty)

      on_exit(fn ->
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(empty)
      end)

      :ok
    end

    test "every path that needs one says so instead of crashing", %{key: key} do
      start!(key, "ghost")

      assert Session.aside(key, "hello") == {:error, :no_agent}
      assert Session.heartbeat(key) == {:error, :no_agent}
      assert Session.learn(key) == {:error, :no_agent}
      assert Session.chat(key, "hello") == {:error, :no_agent}
    end
  end
end
