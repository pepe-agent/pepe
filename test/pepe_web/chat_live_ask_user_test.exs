defmodule PepeWeb.ChatLiveAskUserTest do
  @moduledoc """
  The dashboard's own rendering of an `ask_user` question - real clickable buttons, same
  as the permission prompt already gets. Exercises exactly the LiveView code path
  (`apply_event({:ask_request, ...}, socket)`, the template, and the `ask_user_pick`
  event) directly, rather than driving a whole agent turn through a mock LLM: the
  blocking receive/reply mechanism itself is already proven by the Telegram integration
  test, which shares the identical shape.
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

    home = Path.join(System.tmp_dir!(), "pepe_chatui_ask_#{System.unique_integer([:positive])}")
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

  test "a pending question renders as buttons, and clicking one answers it", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    parent = self()
    send(view.pid, {:session_event, key, {:ask_request, 1, "Coffee or tea?", ["Coffee", "Tea"], parent}})

    html = render(view)
    assert html =~ "Coffee or tea?"
    assert html =~ "Coffee"
    assert html =~ "Tea"

    view
    |> element("button[phx-value-choice=Tea]")
    |> render_click()

    assert_received {:ask_reply, 1, "Tea"}
    refute render(view) =~ "Coffee or tea?"
  end

  test "a stale id (already answered, or from another session) is ignored", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    parent = self()
    send(view.pid, {:session_event, key, {:ask_request, 1, "Pick one", ["A", "B"], parent}})
    render(view)

    # Fire the event with a mismatched id, as a stale/duplicate click might.
    render_click(view, "ask_user_pick", %{"id" => "999", "choice" => "A"})

    refute_received {:ask_reply, _id, _choice}
    # The original prompt is still there - a stale click didn't clear it.
    assert render(view) =~ "Pick one"
  end
end
