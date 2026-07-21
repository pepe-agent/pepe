defmodule PepeWeb.ControlTowerLiveTest do
  @moduledoc """
  Every live session, across every channel, on one screen - the thing `/chat` doesn't
  have (it always shows exactly one conversation). Covers listing sessions from
  `SessionSupervisor.list/0` with their channel/agent/model/turns, the "running now"
  signal actually reflecting a turn in flight, project scoping, filtering, and the
  `Stop` action interrupting a stuck one.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  # A model that answers slowly enough that a test can catch the session mid-turn and
  # assert `running: true` before it finishes on its own.
  defmodule SlowPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      Process.sleep(400)
      message = %{"role" => "assistant", "content" => "done"}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_tower_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "model-a", base_url: "https://x", model: "gpt-a"})
    Config.put_agent(%Agent{name: "assistant", model: "model-a"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  # `SessionSupervisor.list/0` is a process-global registry, not scoped per test - a
  # session left running after one test bleeds into whatever the next test sees
  # (including "no sessions at all"). Every session created in this file must be torn
  # down again, same discipline as `on_exit` already gets everywhere else here.
  defp ensure!(key, agent) do
    {:ok, pid} = SessionSupervisor.ensure(key, agent)
    on_exit(fn -> SessionSupervisor.terminate(key) end)
    pid
  end

  test "an idle session shows its channel, agent, model and turn count" do
    key = "telegram:99001"
    ensure!(key, "assistant")

    {:ok, _view, html} = live(conn(), "/tower")

    assert html =~ "Telegram"
    assert html =~ key
    assert html =~ "assistant"
    assert html =~ "gpt-a"
  end

  test "no live sessions in scope shows the empty state" do
    # A scope no other test (in this file or the wider suite, which shares one process-
    # global Pepe.Agent.Registry) could possibly have a session in, rather than asserting
    # the registry is globally empty - it isn't a guarantee this suite can make.
    scope = "no-such-project-#{System.unique_integer([:positive])}"

    {:ok, _view, html} = live(conn(), "/tower?scope=#{scope}")
    assert html =~ "Nothing live right now"
  end

  test "a session mid-turn shows as running now, then clears once it finishes" do
    {:ok, server} = Bandit.start_link(plug: SlowPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "slow", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "slow"})

    key = "web:99002"
    ensure!(key, "assistant")

    task = Task.async(fn -> Session.chat(key, "hello") end)

    # Give the turn a moment to actually reach the (400ms-slow) plug before we assert on it.
    Process.sleep(150)

    {:ok, view, html} = live(conn(), "/tower")
    assert html =~ "Running now"
    assert has_element?(view, "button[phx-value-key='#{key}']", "Stop")

    Task.await(task, 5_000)

    # `/tower` polls every 3s; poke it via the same message the timer would send rather
    # than actually waiting 3s for the interval to fire.
    send(view.pid, :refresh)
    html = render(view)
    refute html =~ "phx-value-key=\"#{key}\""
  end

  test "stopping a running session from the tower interrupts it", %{} do
    {:ok, server} = Bandit.start_link(plug: SlowPlug, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "slow2", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "slow2"})

    key = "web:99003"
    ensure!(key, "assistant")

    task = Task.async(fn -> Session.chat(key, "hello") end)
    Process.sleep(150)

    {:ok, view, _html} = live(conn(), "/tower")
    assert has_element?(view, "button[phx-value-key='#{key}']", "Stop")

    view |> element("button[phx-value-key='#{key}']") |> render_click()

    assert {:error, :stopped} = Task.await(task, 5_000)
  end

  test "scope hides a session whose agent belongs to a different project" do
    Config.add_project("acme")
    Config.put_agent(%Agent{name: "acme/support", model: "model-a"})

    key = "telegram:99004"
    ensure!(key, "acme/support")

    {:ok, _view, html} = live(conn(), "/tower?scope=root")
    refute html =~ key

    {:ok, _view, html} = live(conn(), "/tower?scope=acme")
    assert html =~ key
  end

  test "filtering by channel narrows the table" do
    ensure!("telegram:99005", "assistant")
    ensure!("web:99006", "assistant")

    {:ok, view, _html} = live(conn(), "/tower")

    html =
      view
      |> form("form[phx-change=filter]", %{"channel" => "telegram"})
      |> render_change()

    assert html =~ "telegram:99005"
    refute html =~ "web:99006"
  end
end
