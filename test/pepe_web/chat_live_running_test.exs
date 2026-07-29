defmodule PepeWeb.ChatLiveRunningTest do
  @moduledoc """
  A session mid-turn shows a live indicator in the sidebar, with a `Stop` button right
  there to interrupt it - no need to open the conversation first. Covers `Session.status/1`'s
  `running` field actually reaching the sidebar, and that `Stop` really does stop the turn
  (not just hide the button).
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

  # A model that answers slowly enough that a test can catch the session mid-turn.
  #
  # The window has to cover a LiveView mount *and* a click, not just the `Process.sleep(150)`
  # each test does before mounting. At 400ms it did not: under a loaded suite the mount alone
  # could eat the remaining 250ms, the answer landed first, and "clicking Stop interrupts the
  # turn" got `{:ok, "done"}` back instead of `{:error, :stopped}` - the run it was supposed
  # to interrupt had already finished. Three seconds is slack, not a weaker assertion: the
  # turn still has to actually stop, it is only given room to still be running when asked to.
  defmodule SlowPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, _body, conn} = read_body(conn)
      Process.sleep(3_000)
      message = %{"role" => "assistant", "content" => "done"}
      payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_running_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: SlowPlug, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    on_exit(fn -> Process.exit(server, :normal) end)

    Config.put_model(%Model{name: "slow", base_url: "http://localhost:#{port}", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "assistant", model: "slow"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs FIRST: a run still in flight has to be stopped while the config
    # and PEPE_HOME it is running against still exist, or it carries on into the next test and
    # calls that test's mock. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    {:ok, key: "web:running-#{System.unique_integer([:positive])}"}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "a session mid-turn shows the running dot and a Stop button in the sidebar", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "assistant")
    on_exit(fn -> SessionSupervisor.terminate(key) end)

    task = Task.async(fn -> Session.chat(key, "hello") end)
    Process.sleep(150)

    {:ok, view, html} = live(conn(), "/chat")
    assert html =~ "Running now"
    assert has_element?(view, "button[phx-value-key='#{key}']", "Stop")

    Task.await(task, 5_000)
  end

  test "clicking Stop from the sidebar interrupts the turn", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "assistant")
    on_exit(fn -> SessionSupervisor.terminate(key) end)

    task = Task.async(fn -> Session.chat(key, "hello") end)
    Process.sleep(150)

    {:ok, view, _html} = live(conn(), "/chat")
    assert has_element?(view, "button[phx-value-key='#{key}']", "Stop")

    view |> element("button[phx-value-key='#{key}'][phx-click=stop_session]") |> render_click()

    assert {:error, :stopped} = Task.await(task, 5_000)
  end

  test "an idle session shows no dot and no Stop button", %{key: key} do
    {:ok, _pid} = SessionSupervisor.ensure(key, "assistant")
    on_exit(fn -> SessionSupervisor.terminate(key) end)

    {:ok, view, _html} = live(conn(), "/chat")
    refute has_element?(view, "button[phx-value-key='#{key}'][phx-click=stop_session]")
  end
end
