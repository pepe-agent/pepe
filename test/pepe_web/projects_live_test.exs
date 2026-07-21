defmodule PepeWeb.ProjectsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_projects_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp save(view, params) do
    view
    |> form("form[phx-submit=project_save]", %{"project" => params})
    |> render_submit()
  end

  defp new_project(view, params) do
    render_click(view, "project_new")
    save(view, params)
  end

  test "the page lists every project plus the principal scope" do
    :ok = Config.add_project("acme")
    :ok = Config.add_project("globex", %{"description" => "Globex Inc"})

    {:ok, _view, html} = live(conn(), "/projects")

    assert html =~ "acme"
    assert html =~ "globex"
    assert html =~ "Globex Inc"
    assert html =~ "Principal"
  end

  test "each project card counts only its own agents" do
    :ok = Config.add_project("acme")
    :ok = Config.add_project("globex")
    Config.put_agent(%Agent{name: "assistant"})
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, _view, html} = live(conn(), "/projects")

    # The delete confirmation is the only per-card place the count is spelled out
    # next to the name, so it pins the count to the right tenant.
    assert html =~ "Delete project acme and its 1 agents?"
    assert html =~ "Delete project globex and its 2 agents?"
  end

  test "creating a project persists it and shows it in the list" do
    {:ok, view, _html} = live(conn(), "/projects")

    html = new_project(view, %{"name" => "acme", "description" => "Acme Inc"})

    assert Config.project_slugs() == ["acme"]
    assert Config.get_project("acme")["description"] == "Acme Inc"
    assert html =~ "Project acme created."
    assert html =~ "Acme Inc"
  end

  test "creating a project with a billing markup and caps stores them" do
    {:ok, view, _html} = live(conn(), "/projects")

    new_project(view, %{
      "name" => "acme",
      "markup" => "1.3",
      "budget" => "100",
      "message_limit" => "5000"
    })

    assert Config.project_markup("acme") == 1.3
    assert Config.project_budget("acme") == 100.0
    assert Config.project_message_limit("acme") == 5000
  end

  test "an invalid project name is refused and nothing is created" do
    {:ok, view, _html} = live(conn(), "/projects")

    html = new_project(view, %{"name" => "acme corp!"})

    assert html =~ "Invalid name."
    assert Config.project_slugs() == []
  end

  test "a duplicate project name is refused and the original is left alone" do
    :ok = Config.add_project("acme", %{"description" => "the first one"})

    {:ok, view, _html} = live(conn(), "/projects")

    html = new_project(view, %{"name" => "acme", "description" => "an impostor"})

    assert html =~ "That project already exists."
    assert Config.project_slugs() == ["acme"]
    assert Config.get_project("acme")["description"] == "the first one"
  end

  test "a blank name keeps the form open with its error and creates nothing" do
    {:ok, view, _html} = live(conn(), "/projects")

    html = new_project(view, %{"name" => ""})

    assert html =~ "Please fix the errors below."
    assert Config.project_slugs() == []
  end

  test "renaming a project re-keys its agents and leaves other projects alone" do
    :ok = Config.add_project("acme")
    :ok = Config.add_project("globex")
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, view, _html} = live(conn(), "/projects")

    render_click(view, "project_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "acme-eu"})

    assert html =~ "Project acme renamed to acme-eu."
    assert Config.project_slugs() == ["acme-eu", "globex"]
    assert Config.agents_in("acme-eu") |> Enum.map(& &1.name) == ["acme-eu/support"]
    assert Config.agents_in("acme") == []
    assert Config.agents_in("globex") |> Enum.map(& &1.name) == ["globex/sales"]
  end

  test "renaming onto an existing project is refused" do
    :ok = Config.add_project("acme")
    :ok = Config.add_project("globex")

    {:ok, view, _html} = live(conn(), "/projects")

    render_click(view, "project_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "globex"})

    assert html =~ "That project already exists."
    assert Config.project_slugs() == ["acme", "globex"]
  end

  test "editing a project updates its metadata without renaming it" do
    :ok = Config.add_project("acme")

    {:ok, view, _html} = live(conn(), "/projects")

    render_click(view, "project_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "acme", "description" => "Acme EU", "budget" => "250"})

    assert html =~ "Project acme updated."
    assert Config.project_slugs() == ["acme"]
    assert Config.get_project("acme")["description"] == "Acme EU"
    assert Config.project_budget("acme") == 250.0
  end

  test "deleting a project removes it and its agents, sparing every other tenant" do
    :ok = Config.add_project("acme")
    :ok = Config.add_project("globex")
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, view, _html} = live(conn(), "/projects")

    html = render_click(view, "project_delete", %{"name" => "acme"})

    assert html =~ "Project acme removed."
    refute html =~ "Delete project acme"
    assert Config.project_slugs() == ["globex"]
    assert Config.agents_in("acme") == []
    assert Config.agents_in("globex") |> Enum.map(& &1.name) == ["globex/sales"]
  end

  test "the principal scope has no name field and saves its billing settings" do
    {:ok, view, _html} = live(conn(), "/projects")

    html = render_click(view, "project_edit", %{"name" => "root"})
    assert html =~ "Edit Principal"
    refute html =~ ~s(name="project[name]")

    html = save(view, %{"markup" => "1.5", "budget" => "80", "message_limit" => "1000"})

    assert html =~ "Principal scope updated."
    assert Config.project_markup(nil) == 1.5
    assert Config.project_budget(nil) == 80.0
    assert Config.project_message_limit(nil) == 1000
    # Root is not a project: editing it must never mint one.
    assert Config.project_slugs() == []
  end

  test "a newly created project's budget badge renders with real numbers, not a stale/missing entry" do
    Config.put_model(%Config.Model{name: "acme/m", model: "gpt-4o", input_price: 1.0, output_price: 0.0})
    {:ok, view, _html} = live(conn(), "/projects")

    # Created mid-session, after mount already built its usage snapshot for the projects that
    # existed then. Without a refresh, this card's badge would read a missing entry and crash the
    # render (KeyError) instead of showing "$0.00 / $50.00".
    html = new_project(view, %{"name" => "acme", "budget" => "50"})
    assert html =~ "$0.00"
    assert html =~ "$50.00"

    Pepe.Usage.record("acme/x", "acme/m", %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})

    # The record above happened outside the LiveView, so nothing has told this connected view to
    # look again yet. Triggering an unrelated event on the SAME project (message-limit reset, not
    # budget) still recomputes ALL of @usage, not just the fields that event is nominally about -
    # proving refresh_usage/1 is a full recompute. (Resetting BUDGET here would set a new
    # reset_at boundary and exclude the spend recorded before it - reset semantics working as
    # intended, just the wrong event to reach for in this test.)
    html = render_click(view, "project_reset_messages", %{"name" => "acme"})
    assert html =~ "$1.00"
  end

  test "a project's spend and message counters can be reset from its card" do
    :ok = Config.add_project("acme", %{"budget" => 10.0, "message_limit" => 100})

    {:ok, view, _html} = live(conn(), "/projects")

    html = render_click(view, "project_reset_budget", %{"name" => "acme"})
    assert html =~ "spend count reset for the rest of this month"
    assert Config.project_budget_reset_at("acme")

    html = render_click(view, "project_reset_messages", %{"name" => "acme"})
    assert html =~ "message count reset for the rest of this month"
    assert Pepe.Usage.messages_reset_at("acme")
  end
end
