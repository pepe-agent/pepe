defmodule PepeWeb.AgentsLiveFallbackTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agentsui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a"})
    Config.put_model(%Model{name: "backup-a", base_url: "https://x", model: "gpt-b"})
    Config.put_model(%Model{name: "backup-b", base_url: "https://x", model: "gpt-c"})
    Config.put_agent(%Agent{name: "assistant", model: "primary"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open_edit(view), do: render_click(view, "agent_edit", %{"name" => "assistant"})

  defp candidate_select(html), do: Regex.run(~r/name="agent_fallback_candidate".*?<\/select>/s, html) |> List.first()

  test "with no override, the form shows the inherit message and no chip editor" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ "Inherits the connection&#39;s own fallback chain."
    refute html =~ "agent_fallback_candidate"
  end

  test "overriding switches to the chip editor with an empty chain" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    html = render_click(view, "agent_fallback_override", %{})
    select = candidate_select(html)
    assert select =~ ~s(<option value="backup-a")
    assert select =~ ~s(<option value="backup-b")
  end

  test "adding, reordering and removing fallbacks works on the override chain" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)
    render_click(view, "agent_fallback_override", %{})

    render_change(view, "agent_fallback_add", %{"agent_fallback_candidate" => "backup-a"})
    html = render_change(view, "agent_fallback_add", %{"agent_fallback_candidate" => "backup-b"})
    assert Regex.run(~r/backup-a.*backup-b/s, html)

    html = render_click(view, "agent_fallback_move", %{"name" => "backup-b", "dir" => "up"})
    assert Regex.run(~r/backup-b.*backup-a/s, html)

    html = render_click(view, "agent_fallback_remove", %{"name" => "backup-a"})
    select = candidate_select(html)
    assert select =~ ~s(<option value="backup-a")
    refute select =~ ~s(<option value="backup-b")
  end

  test "inherit button resets the override back to nil" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)
    render_click(view, "agent_fallback_override", %{})
    render_change(view, "agent_fallback_add", %{"agent_fallback_candidate" => "backup-a"})

    html = render_click(view, "agent_fallback_inherit", %{})
    assert html =~ "Inherits the connection&#39;s own fallback chain."
  end

  test "saving with no override leaves the agent's fallbacks nil" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    assert Config.get_agent("assistant").fallbacks == nil
  end

  test "saving an override persists the chain, in order" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)
    render_click(view, "agent_fallback_override", %{})
    render_change(view, "agent_fallback_add", %{"agent_fallback_candidate" => "backup-b"})
    render_change(view, "agent_fallback_add", %{"agent_fallback_candidate" => "backup-a"})

    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    assert Config.get_agent("assistant").fallbacks == ["backup-b", "backup-a"]
  end

  test "saving an explicit empty override persists as []" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)
    render_click(view, "agent_fallback_override", %{})

    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    assert Config.get_agent("assistant").fallbacks == []
  end
end
