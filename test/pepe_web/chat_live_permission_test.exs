defmodule PepeWeb.ChatLivePermissionTest do
  @moduledoc """
  The dashboard's own rendering of a tool-permission prompt. A tainted run suspends
  `:session`/`:always` grants (see `Pepe.Permissions`' moduledoc), so `:this_run` (offered
  unconditionally now, not just while tainted) is marked "(recommended)" specifically then -
  this pins that the UI says so, rather than presenting equal-looking buttons and leaving
  the person to rediscover that the hard way, one prompt at a time.
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

    home = Path.join(System.tmp_dir!(), "pepe_chatui_perm_#{System.unique_integer([:positive])}")
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

    {:ok, key: "web:test-#{System.unique_integer([:positive])}"}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "an untainted request still offers this_run (unconditionally now), but no taint note", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    parent = self()
    send(view.pid, {:session_event, key, {:permission_request, 1, "bash", parent, false}})

    html = render(view)
    assert html =~ "bash"
    assert html =~ "Allow everything for this task"
    refute html =~ "(recommended)"
    refute html =~ "read something from outside"
  end

  test "a tainted request explains why, and marks this_run as recommended", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    parent = self()
    send(view.pid, {:session_event, key, {:permission_request, 1, "edit_file", parent, true}})

    html = render(view)
    assert html =~ "read something from outside"
    assert html =~ "Allow everything for this task (recommended)"

    view
    |> element(~s(button[phx-value-decision="this_run"]))
    |> render_click()

    assert_received {:perm_reply, 1, :this_run}
  end
end
