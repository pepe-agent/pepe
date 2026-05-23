defmodule PepeWeb.ScheduledLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_cronui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp create(view, params) do
    render_click(view, "cron_new")
    render_submit(view, "cron_create", %{"cron" => params})
  end

  defp cron_fixture(attrs \\ %{}) do
    cron =
      struct(
        %Cron{
          id: "nightly",
          name: "Nightly check",
          agent: "assistant",
          prompt: "check the XML load",
          schedule: "0 8 * * *",
          timezone: "Etc/UTC",
          deliver: "log",
          enabled: true
        },
        attrs
      )

    Config.put_cron(cron)
    cron
  end

  test "an empty page invites the operator to create the first task" do
    {:ok, _view, html} = live(conn(), "/cron")

    assert html =~ "No scheduled tasks yet."
  end

  test "existing tasks are listed with their schedule, agent and state" do
    cron_fixture()
    cron_fixture(%{id: "weekly", name: "Weekly report", schedule: "0 9 * * 1", enabled: false})

    {:ok, _view, html} = live(conn(), "/cron")

    assert html =~ "Nightly check"
    assert html =~ "0 8 * * *"
    assert html =~ "assistant"
    assert html =~ "Weekly report"
    # An enabled task offers "Disable" and a disabled one offers "Enable".
    assert html =~ "Disable"
    assert html =~ "Enable"
  end

  test "creating a task with a preset schedule persists it, enabled" do
    {:ok, view, _html} = live(conn(), "/cron")

    html =
      create(view, %{
        "name" => "Daily XML check",
        "prompt" => "Check the 06:00 XML load and report anything off.",
        "schedule" => "0 8 * * *",
        "timezone" => "Etc/UTC",
        "agent" => "assistant",
        "deliver" => "log"
      })

    assert html =~ "Task created."
    assert html =~ "Daily XML check"

    assert [cron] = Config.crons()
    assert cron.name == "Daily XML check"
    assert cron.schedule == "0 8 * * *"
    assert cron.agent == "default/assistant"
    assert cron.deliver == "log"
    assert cron.enabled
  end

  test "creating a task with a custom schedule persists the custom expression" do
    {:ok, view, _html} = live(conn(), "/cron")

    render_click(view, "cron_new")
    html = render_change(view, "cron_validate", %{"cron" => %{"schedule" => "custom"}})
    assert html =~ ~s(name="cron[schedule_custom]")

    render_submit(view, "cron_create", %{
      "cron" => %{
        "name" => "Weekday standup",
        "prompt" => "Summarize yesterday.",
        "schedule" => "custom",
        "schedule_custom" => "30 9 * * 1-5",
        "agent" => "assistant"
      }
    })

    assert [cron] = Config.crons()
    assert cron.schedule == "30 9 * * 1-5"
  end

  test "an invalid cron expression is rejected and nothing is scheduled" do
    {:ok, view, _html} = live(conn(), "/cron")

    render_click(view, "cron_new")

    html =
      render_submit(view, "cron_create", %{
        "cron" => %{
          "name" => "Broken",
          "prompt" => "do a thing",
          "schedule" => "custom",
          "schedule_custom" => "every other tuesday",
          "agent" => "assistant"
        }
      })

    assert html =~ "Invalid:"
    assert Config.crons() == []
  end

  test "a task with no name or prompt is rejected" do
    {:ok, view, _html} = live(conn(), "/cron")

    html = create(view, %{"name" => "", "prompt" => "", "schedule" => "0 8 * * *"})

    assert html =~ "Please fix the errors below."
    assert Config.crons() == []
  end

  test "the agent dropdown only offers agents from the selected project" do
    :ok = Config.add_project("acme")
    Config.put_agent(%Agent{name: "acme/support"})

    {:ok, view, _html} = live(conn(), "/cron?scope=acme")
    html = render_click(view, "cron_new")

    assert html =~ ~s(<option value="acme/support")
    refute html =~ ~s(<option value="assistant")
  end

  test "disabling a task stops it from being scheduled, and enabling brings it back" do
    cron_fixture()

    {:ok, view, _html} = live(conn(), "/cron")

    html = render_click(view, "cron_toggle", %{"id" => "nightly"})
    refute Config.get_cron("nightly").enabled
    assert html =~ "Enable"
    refute html =~ "Disable"

    html = render_click(view, "cron_toggle", %{"id" => "nightly"})
    assert Config.get_cron("nightly").enabled
    assert html =~ "Disable"
  end

  test "removing a task drops it from the config and from the page" do
    cron_fixture()

    {:ok, view, _html} = live(conn(), "/cron")

    html = render_click(view, "cron_remove", %{"id" => "nightly"})

    assert Config.get_cron("nightly") == nil
    refute html =~ "Nightly check"
    assert html =~ "No scheduled tasks yet."
  end

  test "editing a task keeps its id and enabled flag" do
    cron_fixture(%{enabled: false})

    {:ok, view, _html} = live(conn(), "/cron")

    html = render_click(view, "cron_edit", %{"id" => "nightly"})
    assert html =~ "Edit Nightly check"

    render_submit(view, "cron_create", %{
      "cron" => %{
        "name" => "Nightly check v2",
        "prompt" => "check the XML load twice",
        "schedule" => "0 * * * *",
        "agent" => "assistant"
      }
    })

    assert [cron] = Config.crons()
    assert cron.id == "nightly"
    assert cron.name == "Nightly check v2"
    assert cron.schedule == "0 * * * *"
    refute cron.enabled
  end

  test "acting on a task that no longer exists says so instead of crashing" do
    {:ok, view, _html} = live(conn(), "/cron")

    assert render_click(view, "cron_edit", %{"id" => "ghost"}) =~ "Task not found."
    assert render_click(view, "cron_run", %{"id" => "ghost"}) =~ "Task not found."
    assert Config.crons() == []
  end

  test "the run log shows past runs of a task, and is emptied with it" do
    cron_fixture()
    Pepe.Cron.Log.append("nightly", :manual, true, "all good")

    {:ok, view, _html} = live(conn(), "/cron")

    html = render_click(view, "cron_log", %{"id" => "nightly"})
    assert html =~ "Run log"
    assert html =~ "all good"

    render_click(view, "cron_log_close")
    render_click(view, "cron_remove", %{"id" => "nightly"})
    assert Pepe.Cron.Log.tail("nightly", 10) == []
  end

  test "a task with no runs yet says so" do
    cron_fixture()

    {:ok, view, _html} = live(conn(), "/cron")

    assert render_click(view, "cron_log", %{"id" => "nightly"}) =~ "No runs yet."
  end

  test "a running task shows a live running badge until it finishes" do
    cron_fixture()

    {:ok, view, _html} = live(conn(), "/cron")

    send(view.pid, {:cron_run, :started, "nightly"})
    assert render(view) =~ "Running..."

    send(view.pid, {:cron_run, :finished, "nightly"})
    refute render(view) =~ "Running..."
  end
end
