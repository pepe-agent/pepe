defmodule PepeWeb.ChatLiveStreamedRunTest do
  @moduledoc """
  `apply_event({:done, content}, socket)` used to always show `:done`'s own `content` -
  but that's always the model's raw, un-hooked reply (Runtime emits it before
  `Pepe.Hooks.transform(:outbound, ...)` ever runs). For an agent whose hooks make this a
  buffered (non-streamed) run, showing it would be the first and only place the raw text
  leaked, ahead of `:committed`'s later, correctly-hooked re-read of history. Covers that
  `streamed_run?` (set from `Pepe.Agent.stream_for?/1` when the turn starts) actually gates
  this, without needing a real end-to-end model + hook round trip.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_streamed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    File.write!(Path.join([home, "plugins", "marker.exs"]), """
    defmodule ChatLiveStreamedRunTest.Marker do
      @behaviour Pepe.Hooks.Hook
      def name, do: "marker"
      def stages, do: [:outbound]
      def run(:outbound, text, _settings, _ctx), do: {:ok, "[MUTATED] " <> text}
    end
    """)

    # A dead model - these tests never wait for a real reply, only for handle_event("send", ...)
    # to set streamed_run? (a synchronous config lookup, no network) before driving apply_event
    # directly via synthetic :session_event messages.
    Config.put_model(%Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "plain", model: "dead"})
    Config.put_agent(%Agent{name: "hooked", model: "dead", hooks: ["marker"]})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp send_text(view, text), do: view |> form("form[phx-submit=send]", %{"text" => text}) |> render_submit()

  test "an agent with hooks: :done's raw content never reaches the screen" do
    key = "web:hooked-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, "hooked")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)

    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    send_text(view, "hi")

    send(view.pid, {:session_event, key, {:done, "RAW UNHOOKED TEXT"}})
    html = render(view)
    refute html =~ "RAW UNHOOKED TEXT"
  end

  test "an agent with no hooks: :done's content shows right away, unaffected" do
    key = "web:plain-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, "plain")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)

    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    send_text(view, "hi")

    send(view.pid, {:session_event, key, {:done, "plain reply"}})
    html = render(view)
    assert html =~ "plain reply"
  end
end
