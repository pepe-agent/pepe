defmodule PepeWeb.ChatLiveGoalPanelTest do
  @moduledoc """
  The goal/plan panel under the chat header folds away. It is open while a goal is still being
  worked, folds itself once the goal completes (a finished goal has nothing left to say and the
  checklist is tall), and a click on its header overrides that either way.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Session.Focus

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_goal_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "plain", model: "dead"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open(status) do
    key = "web:goal-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, "plain")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)

    Focus.put_goal(key, %{"objective" => "Ship the router", "status" => status, "criteria" => "it routes"})

    Focus.put_plan(key, [
      %{"title" => "Write persona", "status" => "done"},
      %{"title" => "Create skill", "status" => "in_progress"}
    ])

    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    view
  end

  test "an active goal is open: criterion and checklist visible, progress in the header" do
    html = view_html(open("active"))

    assert html =~ "Ship the router"
    assert html =~ "Done when:"
    assert html =~ "Write persona"
    assert html =~ "1/2"
    assert html =~ ~s(aria-expanded="true")
  end

  test "a completed goal folds itself: only the header row remains" do
    html = view_html(open("complete"))

    assert html =~ "Ship the router"
    assert html =~ "1/2"
    assert html =~ ~s(aria-expanded="false")
    refute html =~ "Write persona"
    refute html =~ "Done when:"
  end

  test "clicking the header overrides the automatic choice, both ways" do
    view = open("active")

    view |> element("button[phx-click=toggle_focus]") |> render_click()
    folded = view_html(view)
    assert folded =~ ~s(aria-expanded="false")
    refute folded =~ "Write persona"

    view |> element("button[phx-click=toggle_focus]") |> render_click()
    assert view_html(view) =~ "Write persona"

    # a finished goal can be unfolded on demand
    done = open("complete")
    done |> element("button[phx-click=toggle_focus]") |> render_click()
    assert view_html(done) =~ "Write persona"
  end

  defp view_html(view), do: render(view)
end
