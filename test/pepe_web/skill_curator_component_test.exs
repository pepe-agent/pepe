defmodule PepeWeb.SkillCuratorComponentTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Skills.Curator.Settings
  alias Pepe.Skills.Curator.State
  alias Pepe.Skills.Lifecycle
  alias Pepe.Skills.Manage
  alias Pepe.Skills.Ownership
  alias Pepe.Skills.Stat

  @endpoint PepeWeb.Endpoint
  @day 86_400

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    home = Path.join(System.tmp_dir!(), "pepe_curator_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "assistant"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp agent_skill(name, days) do
    doc = "---\nname: #{name}\ndescription: Use when you need #{name}.\n---\n\nDo the thing.\n"
    assert {:ok, _} = Manage.create(name, doc, actor: "review", origin: :background, run: "run-#{name}")
    then = System.system_time(:second) - days * @day
    Pepe.Repo.update_all(from(s in Stat, where: s.name == ^name), set: [created_at: then, last_patched_at: then])
  end

  test "the panel shows the curator's state and what is in its care" do
    agent_skill("old-one", 20)

    {:ok, _view, html} = live(conn(), "/learn")

    assert html =~ "Skill curator"
    assert html =~ "Closest to going stale"
    assert html =~ "old-one"
    assert html =~ "idle 20 days"
  end

  test "pausing and resuming flips the automatic runs" do
    {:ok, view, _html} = live(conn(), "/learn")

    html = view |> element("#skill-curator button", "Pause") |> render_click()
    assert State.paused?()
    assert html =~ "Resume"

    html = view |> element("#skill-curator button", "Resume") |> render_click()
    refute State.paused?()
    assert html =~ "Pause"
  end

  test "a preview reports what would happen and changes nothing" do
    agent_skill("long-dead", 45)
    {:ok, view, _html} = live(conn(), "/learn")

    view |> element("#skill-curator button", "Preview") |> render_click()
    html = render_async(view)

    assert html =~ "Preview: nothing was changed"
    assert html =~ "would mark 0 stale, archive 1"
    assert Ownership.origin("long-dead") == :agent
  end

  test "a real run archives, and the archived skill can be restored from the panel" do
    agent_skill("long-dead", 45)
    {:ok, view, _html} = live(conn(), "/learn")

    view |> element("#skill-curator button", "Run now") |> render_click()
    html = render_async(view)

    assert html =~ "Run finished"
    assert Ownership.origin("long-dead") == :missing
    assert [%{name: "long-dead"}] = Lifecycle.archived()

    view |> element("#skill-curator button[phx-click=restore]") |> render_click()
    assert render(view) =~ "Restored long-dead."
    assert Ownership.origin("long-dead") == :agent
  end

  test "pinning takes a skill out of the curator's hands" do
    agent_skill("keep-me", 20)
    {:ok, view, _html} = live(conn(), "/learn")

    view |> element("#skill-curator button[phx-click=pin]") |> render_click()

    assert render(view) =~ "Pinned keep-me"
    refute Ownership.background_writable?("keep-me")
  end

  test "a change can be undone from the panel" do
    agent_skill("short-lived", 1)
    {:ok, view, html} = live(conn(), "/learn")
    assert html =~ "Recent changes to skills"

    view |> element("#skill-curator button[phx-click=undo]") |> render_click()

    assert render(view) =~ "Undid the creation of"
    assert Ownership.origin("short-lived") == :missing
  end

  test "settings are saved, and an impossible pair is refused with a reason" do
    {:ok, view, _html} = live(conn(), "/learn")

    params = %{
      "enabled" => "true",
      "interval_hours" => "24",
      "min_idle_hours" => "1",
      "stale_after_days" => "7",
      "archive_after_days" => "21"
    }

    view |> form("#skill-curator form", params) |> render_submit()
    assert render(view) =~ "Curator settings saved."
    assert Settings.stale_after_days() == 7
    assert Settings.archive_after_days() == 21
    assert Settings.interval_hours() == 24
    refute Settings.consolidate?()

    view |> form("#skill-curator form", %{params | "stale_after_days" => "40"}) |> render_submit()
    assert render(view) =~ "cannot be longer"
    assert Settings.stale_after_days() == 7
  end
end
