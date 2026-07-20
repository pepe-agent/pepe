defmodule Pepe.Agent.SessionMidRunFoldTest do
  @moduledoc """
  `midrun_fold` (+ `triage_model`) lets a message that arrives mid-turn get classified
  instead of always queueing: a correction/clarification of the turn already running
  (FOLD) is sent in the same way `/inline` does, so both callers get the SAME final
  reply; anything else (QUEUE, no triage_model, a slow/crashing classifier) falls back
  to the unconditional-queue behavior every session already has. Follows
  `session_complexity_routing_test.exs`'s pattern (a second mock model standing in for
  the classifier) and keeps a turn reliably "in flight" the same deterministic way -
  the mock announces a hit before an artificial delay, so a test never guesses at
  timing with a bare sleep.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  # Announces the hit BEFORE replying, with an optional delay in between - so a test
  # can reliably know a turn is still in flight (`assert_receive {:hit, :main}`, then
  # act, well inside the delay window) without guessing at timing with a bare sleep.
  defmodule RolePlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(:pepe_mf_test, {:hit, Keyword.fetch!(opts, :role)})
      if delay = opts[:delay_ms], do: Process.sleep(delay)

      message =
        if opts[:tool_first] && needs_tool_call?(body) do
          # A real (short) shell sleep, not a plug-side delay: this gives a genuine,
          # deterministic window during ACTUAL tool execution for a steer to land in the
          # run task's mailbox before the next iteration's drain_steer runs - the exact
          # "correction while the agent is still working on a multi-step task" case
          # midrun_fold exists for.
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{"id" => "c1", "type" => "function", "function" => %{"name" => "bash", "arguments" => ~s({"command":"sleep 0.4"})}}
            ]
          }
        else
          %{"role" => "assistant", "content" => Keyword.fetch!(opts, :reply)}
        end

      payload = %{
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => if(message["tool_calls"], do: "tool_calls", else: "stop")}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end

    # Whether THIS turn still needs its one tool round trip - scoped to the current
    # turn, not "ever in this conversation" (history persists across turns, so a later
    # turn's first call would otherwise see an earlier turn's leftover tool message and
    # skip straight to a final answer with no tool call of its own). Walk back from the
    # end past any trailing user messages (the turn's own opening prompt, or a steer
    # folded in after a tool result): landing on "tool" means the round trip already
    # happened (finalize); landing on anything else (assistant, system, or nothing)
    # means it hasn't (ask for the tool).
    defp needs_tool_call?(body) do
      messages = body |> Jason.decode!() |> Map.fetch!("messages")

      case messages |> Enum.reverse() |> Enum.drop_while(&(&1["role"] == "user")) do
        [%{"role" => "tool"} | _] -> false
        _ -> true
      end
    end
  end

  setup do
    Process.register(self(), :pepe_mf_test)

    home = Path.join(System.tmp_dir!(), "pepe_mf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Two calls, a real sleep in between (via a bash tool call) so there's a genuine
    # window for a steer to land before the second call - see `tool_first` above.
    main_port = start_mock(:main, "final answer", tool_first: true)
    Config.put_model(%Model{name: "main-mock", base_url: "http://localhost:#{main_port}", api_key: "x", model: "m"})

    %{}
  end

  defp start_mock(role, reply, plug_opts) do
    {:ok, server} = Bandit.start_link(plug: {RolePlug, [role: role, reply: reply] ++ plug_opts}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)
    port
  end

  defp put_classify_model(reply, plug_opts \\ []) do
    port = start_mock(:classify, reply, plug_opts)
    Config.put_model(%Model{name: "classify-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    "classify-mock"
  end

  defp put_agent(opts) do
    Config.put_agent(%Agent{
      name: "main",
      model: "main-mock",
      # bash, pre-approved: every turn is a real two-call round trip (tool call, then
      # the final answer), with a genuine sleep in between - see RolePlug's
      # `tool_first`. No permission prompt to gate through; that's a different concern.
      tools: ["bash"],
      auto_approve: ["bash"],
      max_iterations: 5,
      midrun_fold: Keyword.get(opts, :midrun_fold, true),
      triage_model: Keyword.get(opts, :triage_model)
    })
  end

  defp new_key, do: "test:midrun_fold:#{System.unique_integer([:positive])}"

  # Each real turn does exactly one bash round trip in this mock (see `tool_first`), so
  # the number of `tool`-role messages in history is the number of turns that actually
  # ran - the reliable way to tell "folded into one turn" from "ran as two", since the
  # mock always answers the same fixed string regardless of what it's asked.
  defp tool_message_count(key), do: Session.history(key) |> Enum.count(&(&1["role"] == "tool"))

  test "FOLD: a second message classified as a correction folds into the running turn, not a separate one" do
    classify = put_classify_model("FOLD")
    put_agent(triage_model: classify)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    # The first call (asking for the bash tool) - the run is now genuinely mid-turn,
    # sleeping through the tool's real 0.4s execution.
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "wait, make it 3pm") end)
    assert_receive {:hit, :classify}, 2_000

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    assert {:ok, "final answer"} = Task.await(run2, 5_000)

    # ONE turn ran (one bash round trip), and the steered-in text sits as a user
    # message between the tool result and the final answer, inside that same turn.
    assert tool_message_count(key) == 1
    history = Session.history(key)
    assert Enum.map(history, & &1["content"]) |> Enum.take(-2) == ["wait, make it 3pm", "final answer"]
  end

  test "QUEUE: an unrelated second message runs as its own turn after, same as with no classifier" do
    classify = put_classify_model("QUEUE, unrelated topic")
    put_agent(triage_model: classify)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "unrelated: what's the weather") end)
    assert_receive {:hit, :classify}, 2_000

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    # The second call ran as its own turn: two more :main hits (its own tool round trip).
    assert_receive {:hit, :main}, 5_000
    assert_receive {:hit, :main}, 5_000
    assert {:ok, "final answer"} = Task.await(run2, 5_000)

    # TWO separate turns (two bash round trips), unlike the FOLD case above.
    assert tool_message_count(key) == 2
  end

  test "midrun_fold off (the default) never classifies - queues exactly like before this feature existed" do
    classify = put_classify_model("FOLD")
    put_agent(midrun_fold: false, triage_model: classify)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "wait, make it 3pm") end)
    refute_receive {:hit, :classify}, 300

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    assert_receive {:hit, :main}, 5_000
    assert_receive {:hit, :main}, 5_000
    assert {:ok, "final answer"} = Task.await(run2, 5_000)
    assert tool_message_count(key) == 2
  end

  test "midrun_fold on with no triage_model set classifies via the agent's own model instead of skipping" do
    put_agent(midrun_fold: true, triage_model: nil)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "wait, make it 3pm") end)
    # No triage_model configured - the classification call itself lands on the
    # agent's own model connection (main-mock), a second :main hit, proving the
    # fallback actually dispatches rather than silently skipping like before.
    assert_receive {:hit, :main}, 2_000

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    assert_receive {:hit, :main}, 5_000
    assert_receive {:hit, :main}, 5_000
    assert {:ok, "final answer"} = Task.await(run2, 5_000)

    # The mock's own-model answer to the classify prompt doesn't read as a
    # correction, so it queues (two separate turns) rather than folding - the safe
    # default, and this test's job is only to prove the call itself landed.
    assert tool_message_count(key) == 2
  end

  test "an unreachable classifier fails safe to QUEUE, not a hang or a lost message" do
    Config.put_model(%Model{name: "dead-classify", base_url: "http://localhost:1", api_key: "x", model: "m"})
    put_agent(triage_model: "dead-classify")
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "wait, make it 3pm") end)

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    assert_receive {:hit, :main}, 8_000
    assert_receive {:hit, :main}, 8_000
    assert {:ok, "final answer"} = Task.await(run2, 8_000)
    assert tool_message_count(key) == 2
  end

  test "a third message arriving while the second is still classifying queues directly, no stacked classification" do
    # Delayed so there's a reliable window, confirmed by the hit itself (not a guessed
    # sleep), where the second message's classification has started but not resolved.
    classify = put_classify_model("FOLD", delay_ms: 400)
    put_agent(triage_model: classify)
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "main")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :main}, 2_000

    run2 = Task.async(fn -> Session.chat(key, "wait, make it 3pm") end)
    assert_receive {:hit, :classify}, 2_000

    # Fired while run2's classification is confirmed in flight (still sleeping above).
    run3 = Task.async(fn -> Session.chat(key, "also unrelated") end)

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    assert {:ok, "final answer"} = Task.await(run2, 5_000)
    # run3 queued directly (never classified) and ran as its own turn.
    assert_receive {:hit, :main}, 5_000
    assert_receive {:hit, :main}, 5_000
    assert {:ok, "final answer"} = Task.await(run3, 5_000)
    # run1+run2 folded into one turn, run3 ran as its own - two total.
    assert tool_message_count(key) == 2
  end

  # A minimal single-call mock (no bash round trip) with a delay on its one and only
  # response - just enough room to fire `/inline` while that response is in flight, to
  # cover the OTHER new code path this feature's bonus fix touches: a steer that
  # arrives after the loop's last drain_steer call (there is no second iteration to
  # drain it, unlike the FOLD tests above, which fold into a *second* iteration).
  defmodule SlowFinalPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      send(:pepe_mf_test, {:hit, :slow_final})
      Process.sleep(400)

      payload = %{
        "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => "final answer"}, "finish_reason" => "stop"}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  test "an /inline steer that arrives after the turn's last model call still reaches the model, as a follow-up turn, instead of being lost" do
    {:ok, server} = Bandit.start_link(plug: SlowFinalPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "slow-final-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "slowfinal", model: "slow-final-mock", tools: [], max_iterations: 5})
    key = new_key()
    {:ok, _pid} = SessionSupervisor.ensure(key, "slowfinal")

    run1 = Task.async(fn -> Session.chat(key, "book 2pm") end)
    assert_receive {:hit, :slow_final}, 2_000

    # /inline's own contract: acks immediately, doesn't wait for the turn.
    assert Session.inline(key, "actually, make it 3pm") == :ok

    assert {:ok, "final answer"} = Task.await(run1, 5_000)
    # The steer arrived too late for the turn it was aimed at (which had already
    # started its one and only model call) - it must still reach the model as its
    # own follow-up turn rather than vanish. That's a SECOND call to the mock.
    assert_receive {:hit, :slow_final}, 5_000

    # The plug announces the hit before its own reply delay, so the follow-up turn
    # hasn't committed to history yet at this point - poll instead of racing it.
    history = wait_for_user_count(key, 2, 2_000)
    assert Enum.count(history, &(&1["role"] == "user")) == 2
    assert Enum.count(history, &(&1["role"] == "assistant")) == 2
  end

  defp wait_for_user_count(key, count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_user_count(key, count, deadline)
  end

  defp do_wait_for_user_count(key, count, deadline) do
    history = Session.history(key)

    cond do
      Enum.count(history, &(&1["role"] == "user")) >= count ->
        history

      System.monotonic_time(:millisecond) >= deadline ->
        history

      true ->
        Process.sleep(20)
        do_wait_for_user_count(key, count, deadline)
    end
  end
end
