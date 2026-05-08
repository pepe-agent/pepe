defmodule PepeWeb.CompaniesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_companies_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp save(view, params) do
    view
    |> form("form[phx-submit=company_save]", %{"company" => params})
    |> render_submit()
  end

  defp new_company(view, params) do
    render_click(view, "company_new")
    save(view, params)
  end

  test "the page lists every company plus the principal scope" do
    :ok = Config.add_company("acme")
    :ok = Config.add_company("globex", %{"description" => "Globex Inc"})

    {:ok, _view, html} = live(conn(), "/companies")

    assert html =~ "acme"
    assert html =~ "globex"
    assert html =~ "Globex Inc"
    assert html =~ "Principal"
  end

  test "each company card counts only its own agents" do
    :ok = Config.add_company("acme")
    :ok = Config.add_company("globex")
    Config.put_agent(%Agent{name: "assistant"})
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, _view, html} = live(conn(), "/companies")

    # The delete confirmation is the only per-card place the count is spelled out
    # next to the name, so it pins the count to the right tenant.
    assert html =~ "Delete company acme and its 1 agents?"
    assert html =~ "Delete company globex and its 2 agents?"
  end

  test "creating a company persists it and shows it in the list" do
    {:ok, view, _html} = live(conn(), "/companies")

    html = new_company(view, %{"name" => "acme", "description" => "Acme Inc"})

    assert Config.companies() == ["acme"]
    assert Config.get_company("acme")["description"] == "Acme Inc"
    assert html =~ "Company acme created."
    assert html =~ "Acme Inc"
  end

  test "creating a company with a billing markup and caps stores them" do
    {:ok, view, _html} = live(conn(), "/companies")

    new_company(view, %{
      "name" => "acme",
      "markup" => "1.3",
      "budget" => "100",
      "message_limit" => "5000"
    })

    assert Config.company_markup("acme") == 1.3
    assert Config.company_budget("acme") == 100.0
    assert Config.company_message_limit("acme") == 5000
  end

  test "an invalid company name is refused and nothing is created" do
    {:ok, view, _html} = live(conn(), "/companies")

    html = new_company(view, %{"name" => "acme corp!"})

    assert html =~ "Invalid name."
    assert Config.companies() == []
  end

  test "a duplicate company name is refused and the original is left alone" do
    :ok = Config.add_company("acme", %{"description" => "the first one"})

    {:ok, view, _html} = live(conn(), "/companies")

    html = new_company(view, %{"name" => "acme", "description" => "an impostor"})

    assert html =~ "That company already exists."
    assert Config.companies() == ["acme"]
    assert Config.get_company("acme")["description"] == "the first one"
  end

  test "a blank name keeps the form open with its error and creates nothing" do
    {:ok, view, _html} = live(conn(), "/companies")

    html = new_company(view, %{"name" => ""})

    assert html =~ "Please fix the errors below."
    assert Config.companies() == []
  end

  test "renaming a company re-keys its agents and leaves other companies alone" do
    :ok = Config.add_company("acme")
    :ok = Config.add_company("globex")
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, view, _html} = live(conn(), "/companies")

    render_click(view, "company_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "acme-eu"})

    assert html =~ "Company acme renamed to acme-eu."
    assert Config.companies() == ["acme-eu", "globex"]
    assert Config.agents_in("acme-eu") |> Enum.map(& &1.name) == ["acme-eu/support"]
    assert Config.agents_in("acme") == []
    assert Config.agents_in("globex") |> Enum.map(& &1.name) == ["globex/sales"]
  end

  test "renaming onto an existing company is refused" do
    :ok = Config.add_company("acme")
    :ok = Config.add_company("globex")

    {:ok, view, _html} = live(conn(), "/companies")

    render_click(view, "company_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "globex"})

    assert html =~ "That company already exists."
    assert Config.companies() == ["acme", "globex"]
  end

  test "editing a company updates its metadata without renaming it" do
    :ok = Config.add_company("acme")

    {:ok, view, _html} = live(conn(), "/companies")

    render_click(view, "company_edit", %{"name" => "acme"})
    html = save(view, %{"name" => "acme", "description" => "Acme EU", "budget" => "250"})

    assert html =~ "Company acme updated."
    assert Config.companies() == ["acme"]
    assert Config.get_company("acme")["description"] == "Acme EU"
    assert Config.company_budget("acme") == 250.0
  end

  test "deleting a company removes it and its agents, sparing every other tenant" do
    :ok = Config.add_company("acme")
    :ok = Config.add_company("globex")
    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_agent(%Agent{name: "globex/sales"})

    {:ok, view, _html} = live(conn(), "/companies")

    html = render_click(view, "company_delete", %{"name" => "acme"})

    assert html =~ "Company acme removed."
    refute html =~ "Delete company acme"
    assert Config.companies() == ["globex"]
    assert Config.agents_in("acme") == []
    assert Config.agents_in("globex") |> Enum.map(& &1.name) == ["globex/sales"]
  end

  test "the principal scope has no name field and saves its billing settings" do
    {:ok, view, _html} = live(conn(), "/companies")

    html = render_click(view, "company_edit", %{"name" => "root"})
    assert html =~ "Edit Principal"
    refute html =~ ~s(name="company[name]")

    html = save(view, %{"markup" => "1.5", "budget" => "80", "message_limit" => "1000"})

    assert html =~ "Principal scope updated."
    assert Config.company_markup(nil) == 1.5
    assert Config.company_budget(nil) == 80.0
    assert Config.company_message_limit(nil) == 1000
    # Root is not a company: editing it must never mint one.
    assert Config.companies() == []
  end

  test "a company's spend and message counters can be reset from its card" do
    :ok = Config.add_company("acme", %{"budget" => 10.0, "message_limit" => 100})

    {:ok, view, _html} = live(conn(), "/companies")

    html = render_click(view, "company_reset_budget", %{"name" => "acme"})
    assert html =~ "spend count reset for the rest of this month"
    assert Config.company_budget_reset_at("acme")

    html = render_click(view, "company_reset_messages", %{"name" => "acme"})
    assert html =~ "message count reset for the rest of this month"
    assert Pepe.Usage.messages_reset_at("acme")
  end
end
