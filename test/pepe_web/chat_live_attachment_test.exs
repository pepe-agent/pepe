defmodule PepeWeb.ChatLiveAttachmentTest do
  @moduledoc """
  `send_file`'s dashboard delivery (Pepe.Tools.SendFile, "web:" session clause) has no bot
  API to push a document through, unlike Telegram/WhatsApp/Slack - it broadcasts a
  `:file_ready` session event instead, and this pins that ChatLive turns that into an
  actual download link rather than a raw server filesystem path nobody at the keyboard
  can reach.
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

    home = Path.join(System.tmp_dir!(), "pepe_chatui_attach_#{System.unique_integer([:positive])}")
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

  test "a :file_ready event renders a download link to the token's route", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    send(view.pid, {:session_event, key, {:file_ready, "tok-abc", "report.xlsx", "here you go"}})

    html = render(view)
    assert html =~ ~s(href="/dashboard/files/tok-abc")
    assert html =~ "report.xlsx"
    assert html =~ "here you go"
  end

  test "an attachment with no caption renders without one", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    send(view.pid, {:session_event, key, {:file_ready, "tok-xyz", "leads.csv", nil}})

    html = render(view)
    assert html =~ "leads.csv"
  end

  test "resetting the conversation clears the attachment strip", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    send(view.pid, {:session_event, key, {:file_ready, "tok-1", "old.csv", nil}})
    assert render(view) =~ "old.csv"

    view |> element(~s(button[phx-click="reset"])) |> render_click()

    refute render(view) =~ "old.csv"
  end
end
