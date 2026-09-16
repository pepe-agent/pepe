defmodule PepeWeb.ChatLiveRenameTest do
  @moduledoc """
  The header's rename control - a pencil next to the conversation title that swaps in an
  inline text field, alongside the pre-existing `/name` slash command. The auto-generated
  title (Pepe.Agent.SessionTitles) is a starting point, never something the operator is
  stuck with.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Agent.SessionTitles
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_rename_#{System.unique_integer([:positive])}")
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

  defp open do
    key = "web:rename-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, "plain")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    {view, key}
  end

  test "the pencil opens an inline field pre-filled with the current title" do
    {view, key} = open()
    SessionTitles.set(key, "Docker deploy question")

    refute render(view) =~ "chat-rename-input"
    html = view |> element(~s(button[phx-click="start_rename"])) |> render_click()

    assert html =~ "chat-rename-input"
    assert html =~ "Docker deploy question"
  end

  test "submitting the field relabels the session and closes the field" do
    {view, key} = open()

    view |> element(~s(button[phx-click="start_rename"])) |> render_click()
    html = view |> form("#chat-rename", %{"title" => "Billing question"}) |> render_submit()

    assert SessionTitles.get(key) == "Billing question"
    assert html =~ "Billing question"
    refute html =~ "chat-rename-input"
  end

  test "cancel leaves the previous title untouched" do
    {view, key} = open()
    SessionTitles.set(key, "Original name")

    view |> element(~s(button[phx-click="start_rename"])) |> render_click()
    html = view |> element(~s(button[phx-click="cancel_rename"])) |> render_click()

    assert SessionTitles.get(key) == "Original name"
    assert html =~ "Original name"
    refute html =~ "chat-rename-input"
  end

  test "an empty title clears the label back to the auto-generated one" do
    {view, key} = open()
    SessionTitles.set(key, "Will be cleared")

    view |> element(~s(button[phx-click="start_rename"])) |> render_click()
    view |> form("#chat-rename", %{"title" => "   "}) |> render_submit()

    assert SessionTitles.get(key) == nil
  end

  test "switching to a different chat closes any open rename field" do
    {view, _key} = open()
    view |> element(~s(button[phx-click="start_rename"])) |> render_click()
    assert render(view) =~ "chat-rename-input"

    other_key = "web:rename-other-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(other_key, "plain")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(other_key) end)

    html = view |> render_patch("/chat?chat=#{other_key}")
    refute html =~ "chat-rename-input"
  end
end
