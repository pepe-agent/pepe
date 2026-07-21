defmodule Pepe.Commitments.SchedulerTest do
  @moduledoc """
  Drives `Pepe.Commitments.Scheduler` directly (`send(Scheduler, :tick)`), same pattern as
  `watch_scheduler_test.exs`. Covers the one thing that makes this scheduler different from
  Watch's: a `user_reminder` delivers a canned message, an `agent_promise` re-runs a real
  session and delivers whatever it actually replies with.
  """
  use ExUnit.Case, async: false

  alias Pepe.Commitments.Scheduler
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Commitment
  alias Pepe.Config.Model
  alias Pepe.Watch.Delivery

  defmodule MainPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      message = %{"role" => "assistant", "content" => Keyword.fetch!(opts, :reply)}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # Slow enough that a test can grab the in-flight fire task before it finishes.
  defmodule SlowPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      Process.sleep(5_000)
      message = %{"role" => "assistant", "content" => "too slow"}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_csch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{}))

    start_supervised!({Task.Supervisor, name: Pepe.Commitments.TaskSupervisor})
    start_supervised!(Scheduler)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp put(attrs) do
    c = struct(%Commitment{id: "c#{System.unique_integer([:positive])}", due_at: System.system_time(:second) - 10}, attrs)
    Config.put_commitment(c)
    c.id
  end

  defp tick, do: send(Scheduler, :tick)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp busy?(id), do: MapSet.member?(:sys.get_state(Scheduler).busy, id)

  defp wait_for_child do
    wait_until(fn -> Task.Supervisor.children(Pepe.Commitments.TaskSupervisor) != [] end)
    [pid] = Task.Supervisor.children(Pepe.Commitments.TaskSupervisor)
    pid
  end

  test "a due user_reminder delivers its canned text and becomes delivered" do
    origin = %{"channel" => "ws", "key" => "ws:reminder-#{System.unique_integer([:positive])}"}
    {:ok, _} = Registry.register(Pepe.Watch.Subscribers, Delivery.topic(origin), nil)
    Phoenix.PubSub.subscribe(Pepe.PubSub, Delivery.topic(origin))

    id = put(state: "scheduled", origin_type: "user_reminder", text: "send the report", origin: origin)

    tick()
    assert_receive {:watch_message, ^origin, "send the report"}, 2_000
    wait_until(fn -> match?(%{state: "delivered"}, Config.get_commitment(id)) end)
    assert Config.get_commitment(id).pending_delivery == nil
  end

  test "a due agent_promise re-runs the original session and delivers its real reply" do
    {:ok, server} = Bandit.start_link(plug: {MainPlug, reply: "checked - all good, deploy succeeded"}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "main-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "main-mock", tools: []})

    origin = %{"channel" => "ws", "key" => "ws:promise-#{System.unique_integer([:positive])}"}
    {:ok, _} = Registry.register(Pepe.Watch.Subscribers, Delivery.topic(origin), nil)
    Phoenix.PubSub.subscribe(Pepe.PubSub, Delivery.topic(origin))

    id =
      put(
        state: "scheduled",
        origin_type: "agent_promise",
        text: "check the deploy and report back",
        agent: "assistant",
        origin: origin
      )

    tick()
    assert_receive {:watch_message, ^origin, "checked - all good, deploy succeeded"}, 5_000
    wait_until(fn -> match?(%{state: "delivered"}, Config.get_commitment(id)) end)
  end

  test "an agent_promise persists \"firing\" before running the session, not after" do
    {:ok, server} = Bandit.start_link(plug: {MainPlug, reply: "done"}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "firing-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "firing-mock", tools: []})

    origin = %{"channel" => "ws", "key" => "ws:firing-#{System.unique_integer([:positive])}"}
    {:ok, _} = Registry.register(Pepe.Watch.Subscribers, Delivery.topic(origin), nil)
    Phoenix.PubSub.subscribe(Pepe.PubSub, Delivery.topic(origin))

    id =
      put(
        state: "scheduled",
        origin_type: "agent_promise",
        text: "check something",
        agent: "assistant",
        origin: origin
      )

    tick()
    # The intermediate state is real and timestamped, not skipped straight to "delivered" -
    # this is the checkpoint that makes a crash mid-fire distinguishable from "never fired".
    wait_until(fn -> match?(%{state: s} when s in ["firing", "delivered"], Config.get_commitment(id)) end)
    assert Config.get_commitment(id).firing_at != nil

    assert_receive {:watch_message, ^origin, "done"}, 5_000
    wait_until(fn -> match?(%{state: "delivered"}, Config.get_commitment(id)) end)
  end

  test "a commitment stuck \"firing\" from a crash is never re-fired automatically" do
    test_pid = self()

    defmodule NeverCalledPlug do
      @moduledoc false
      import Plug.Conn

      def init(opts), do: opts

      def call(conn, opts) do
        send(Keyword.fetch!(opts, :test_pid), :model_was_called)
        {:ok, _body, conn} = read_body(conn)
        message = %{"role" => "assistant", "content" => "should never happen"}
        payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end

    {:ok, server} = Bandit.start_link(plug: {NeverCalledPlug, test_pid: test_pid}, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "stuck-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "stuck-mock", tools: []})

    # Simulates a crash right after run_fire/1 persisted "firing" but before produce_text
    # (a real agent turn) returned - the scheduler restarted with a fresh, empty `busy`.
    id =
      put(
        state: "firing",
        firing_at: System.system_time(:second) - 3600,
        origin_type: "agent_promise",
        text: "check something",
        agent: "assistant"
      )

    tick()
    # Give a wrongly-re-firing scheduler a real chance to hit the plug before concluding it didn't.
    refute_receive :model_was_called, 500
    assert Config.get_commitment(id).state == "firing"
  end

  test "a fire task that crashes releases the busy guard instead of leaking it forever" do
    {:ok, server} = Bandit.start_link(plug: SlowPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "slow-mock", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "slow-mock", tools: []})

    id =
      put(
        state: "scheduled",
        origin_type: "agent_promise",
        text: "check something",
        agent: "assistant"
      )

    tick()
    wait_until(fn -> busy?(id) end)

    pid = wait_for_child()
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    # The scheduler's own guard clears too, not just the OS process. It won't re-fire this
    # commitment (state is "firing", not "scheduled" - see the at-most-once test above),
    # but it must not stay marked busy forever either, or a legitimate later commitment
    # sharing no relation to this one would never be the reason it's stuck - busy is
    # per-id, so leaking it here only affects this same id, yet it must still clear.
    wait_until(fn -> not busy?(id) end)
  end

  test "a delivery that can't reach anyone holds the text for the next tick" do
    origin = %{"channel" => "ws", "key" => "ws:offline-#{System.unique_integer([:positive])}"}

    id = put(state: "scheduled", origin_type: "user_reminder", text: "held for later", origin: origin)

    tick()
    wait_until(fn -> match?(%{state: "delivered"}, Config.get_commitment(id)) end)
    assert Config.get_commitment(id).pending_delivery == "held for later"
  end
end
