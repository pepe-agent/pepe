defmodule PepeWeb.AgentsLiveDraftTest do
  @moduledoc """
  The agent editor keeps what you change as a draft (saved as you go, not live) until Save
  publishes it, and splits its long form into tabs. Every tab's fields stay in one form, so
  what you typed on a tab you have since left still saves.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Drafts

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agents_draft_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_model(%Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"})
    Config.put_agent(%Agent{name: "helper", model: "dead", system_prompt: "You help.", tools: ["bash"]})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp handle, do: Config.agents() |> Enum.find(&(&1.name =~ "helper")) |> Map.fetch!(:name)

  defp edit_helper do
    {:ok, view, _html} = live(conn(), "/agents")
    view |> element(~s(button[phx-click=agent_edit][phx-value-name="#{handle()}"])) |> render_click()
    view
  end

  defp change_persona(view, text) do
    view |> form("#agent-form", %{"system_prompt" => text}) |> render_change()
  end

  test "opening the editor starts with no draft, and the form is split into tabs" do
    view = edit_helper()
    html = render(view)

    assert html =~ "No unsaved changes."
    assert html =~ ~s(role="tablist")
    for tab <- ~w(persona model capabilities access limits), do: assert(html =~ ~s(id="agent-tab-#{tab}"))
    assert Drafts.get("agent", handle()) == nil
  end

  test "a change is saved as a draft at once, and the real config is untouched" do
    view = edit_helper()
    html = change_persona(view, "You help, briefly.")

    assert html =~ "Draft saved."
    assert %{data: %{"edit" => %{"system_prompt" => "You help, briefly."}}} = Drafts.get("agent", handle())
    assert Config.get_agent(handle()).system_prompt == "You help."
  end

  test "leaving keeps the draft: the list marks the agent and reopening restores the text" do
    view = edit_helper()
    change_persona(view, "Half-written thought")
    view |> element("button[type=button][phx-click=agent_cancel]") |> render_click()

    assert render(view) =~ "Draft"

    view |> element(~s(button[phx-click=agent_edit][phx-value-name="#{handle()}"])) |> render_click()
    html = render(view)
    assert html =~ "Half-written thought"
    assert html =~ "Draft saved."
  end

  test "Save publishes the draft to the config and deletes it; the next change starts a new one" do
    view = edit_helper()
    change_persona(view, "Published persona")
    view |> form("#agent-form") |> render_submit()

    assert Config.get_agent(handle()).system_prompt == "Published persona"
    assert Drafts.get("agent", handle()) == nil

    view |> element(~s(button[phx-click=agent_edit][phx-value-name="#{handle()}"])) |> render_click()
    assert render(view) =~ "No unsaved changes."

    change_persona(view, "Second round")
    assert %{data: %{"edit" => %{"system_prompt" => "Second round"}}} = Drafts.get("agent", handle())
  end

  test "Discard throws the draft away and shows the saved version again" do
    view = edit_helper()
    change_persona(view, "Something I regret")

    html = view |> element("button[phx-click=agent_discard_draft]") |> render_click()

    assert Drafts.get("agent", handle()) == nil
    assert html =~ "You help."
    assert html =~ "No unsaved changes."
  end

  test "switching tabs marks the active one and does not lose or save anything" do
    view = edit_helper()
    change_persona(view, "Typed on the first tab")

    html = view |> element(~s(button[role=tab][phx-value-tab=access])) |> render_click()

    assert html =~ ~s(aria-selected="true")
    assert html =~ "Typed on the first tab"
    assert Config.get_agent(handle()).system_prompt == "You help."
  end

  test "an agent that changed after the draft began is flagged instead of silently overwritten" do
    view = edit_helper()
    change_persona(view, "My edit")
    view |> element("button[type=button][phx-click=agent_cancel]") |> render_click()

    Config.put_agent(%{Config.get_agent(handle()) | system_prompt: "Changed from the CLI"})

    view |> element(~s(button[phx-click=agent_edit][phx-value-name="#{handle()}"])) |> render_click()
    assert render(view) =~ "changed since the draft was started"
  end
end
