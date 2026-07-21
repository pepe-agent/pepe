defmodule PepeWeb.CommitmentsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Commitment

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_commitui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "an empty page says so" do
    {:ok, _view, html} = live(conn(), "/commitments")
    assert html =~ "No commitments yet."
  end

  test "lists commitments grouped by state" do
    {:ok, awaiting} =
      Config.create_commitment(%Commitment{
        text: "check the deploy",
        agent: "assistant",
        state: "awaiting_confirmation",
        due_when: "amanhã",
        due_at: System.system_time(:second) + 86_400
      })

    {:ok, _scheduled} =
      Config.create_commitment(%Commitment{
        text: "send the report",
        agent: "assistant",
        state: "scheduled",
        due_when: "sexta",
        due_at: System.system_time(:second) + 86_400
      })

    {:ok, view, html} = live(conn(), "/commitments")

    assert html =~ "Awaiting your ok"
    assert html =~ "check the deploy"
    assert html =~ "Scheduled"
    assert html =~ "send the report"

    html = render_click(view, "confirm", %{"id" => awaiting.id})
    assert Config.get_commitment(awaiting.id).state == "scheduled"
    refute html =~ "Awaiting your ok"
  end

  test "an unresolved due date gets an inline form instead of a Confirm button that does nothing" do
    {:ok, c} =
      Config.create_commitment(%Commitment{
        text: "look into it",
        agent: "assistant",
        state: "awaiting_confirmation",
        due_when: "sexta",
        due_at: nil
      })

    {:ok, view, html} = live(conn(), "/commitments")

    # No plain Confirm button for this one - it would have silently done nothing.
    refute has_element?(view, "button[phx-click=confirm][phx-value-id='#{c.id}']")
    assert html =~ "Confirm with this date"

    html = render_submit(view, "confirm_with_date", %{"commitment_id" => c.id, "due_when" => "not a real date"})
    assert html =~ "Still need a clear due time"
    assert Config.get_commitment(c.id).state == "awaiting_confirmation"

    render_submit(view, "confirm_with_date", %{"commitment_id" => c.id, "due_when" => "amanhã"})
    updated = Config.get_commitment(c.id)
    assert updated.state == "scheduled"
    assert is_integer(updated.due_at)
    assert updated.due_when == "amanhã"
  end

  test "a commitment stuck firing shows up, not silently invisible, with a way to cancel it" do
    {:ok, c} =
      Config.create_commitment(%Commitment{
        text: "check the deploy",
        agent: "assistant",
        state: "firing",
        firing_at: System.system_time(:second) - 3600
      })

    {:ok, view, html} = live(conn(), "/commitments")
    assert html =~ "Stuck"
    assert html =~ "check the deploy"

    render_click(view, "cancel", %{"id" => c.id})
    assert Config.get_commitment(c.id) == nil
  end

  test "cancel removes a commitment" do
    {:ok, c} = Config.create_commitment(%Commitment{text: "ping the user", agent: "assistant", state: "scheduled"})

    {:ok, view, _html} = live(conn(), "/commitments")
    html = render_click(view, "cancel", %{"id" => c.id})

    assert Config.get_commitment(c.id) == nil
    refute html =~ "ping the user"
  end
end
