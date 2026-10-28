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

  test "a picture is shown inline as well as linked, other files are only linked", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    send(view.pid, {:session_event, key, {:file_ready, "tok-img", "orders.png", "Orders per week"}})
    send(view.pid, {:session_event, key, {:file_ready, "tok-doc", "orders.xlsx", nil}})

    html = render(view)
    assert html =~ ~s(<img src="/dashboard/files/tok-img")
    assert html =~ ~s(alt="Orders per week")
    refute html =~ ~s(<img src="/dashboard/files/tok-doc")
    assert html =~ ~s(href="/dashboard/files/tok-doc")
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

  test "files come back when the conversation is reopened, and /new deletes them", %{key: key} do
    src = Path.join(System.tmp_dir!(), "reopen_#{System.unique_integer([:positive])}.csv")
    File.write!(src, "a,b")
    on_exit(fn -> File.rm(src) end)
    {:ok, %{token: token}} = Pepe.ChatFiles.put(key, src, "kept", 1)

    {:ok, view, html} = live(conn(), "/chat?chat=#{key}")
    assert html =~ ~s(href="/dashboard/files/#{token}")

    view |> form("#chat-compose", %{"text" => "/new"}) |> render_submit()

    refute render(view) =~ token
    assert Pepe.ChatFiles.list(key) == []
    assert Pepe.ChatFiles.find(token) == :error
  end

  test "a file lands after its own turn's reply, above the next question" do
    messages = [
      %{role: "user", content: "q1"},
      %{role: "assistant", content: "a1"},
      %{role: "user", content: "q2"},
      %{role: "assistant", content: "a2"}
    ]

    files = [%{turn: 1, token: "t1"}, %{turn: 2, token: "t2"}]

    assert [
             {:message, %{content: "q1"}},
             {:message, %{content: "a1"}},
             {:file, %{token: "t1"}},
             {:message, %{content: "q2"}},
             {:message, %{content: "a2"}},
             {:file, %{token: "t2"}}
           ] = PepeWeb.ChatLive.timeline(messages, files, 50, false)
  end

  test "while a run is live its files are held back for after the streaming reply" do
    messages = [%{role: "user", content: "q1"}, %{role: "assistant", content: "a1"}, %{role: "user", content: "q2"}]
    files = [%{turn: 1, token: "t1"}, %{turn: 2, token: "t2"}]

    entries = PepeWeb.ChatLive.timeline(messages, files, 50, true)

    assert Enum.any?(entries, &match?({:file, %{token: "t1"}}, &1))
    refute Enum.any?(entries, &match?({:file, %{token: "t2"}}, &1))
  end
end
