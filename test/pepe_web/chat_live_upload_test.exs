defmodule PepeWeb.ChatLiveUploadTest do
  @moduledoc """
  The dashboard composer's file upload - the other half of `send_file` (Pepe.Tools.SendFile)
  now working from the dashboard: an operator can also send a file *to* the agent, not just
  receive a download link from it. Mirrors the Telegram gateway's own attached-document
  handling: the file lands in the agent's workspace, its extracted text (or, for an image on
  a vision-capable agent, the image itself) rides into the very same turn as the typed
  caption, and the turn is born untrusted - a file is content someone else could have put
  words into, whoever is doing the uploading.
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

    home = Path.join(System.tmp_dir!(), "pepe_chatui_upload_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # A dead model - these tests only need handle_event("send", ...) to consume the staged
    # upload and start the run; they never wait for a real reply.
    Config.put_model(%Model{name: "dead", base_url: "http://localhost:1", api_key: "x", model: "m"})
    Config.put_model(%Model{name: "seer", base_url: "http://localhost:1", api_key: "x", model: "m", vision: true})
    Config.put_agent(%Agent{name: "plain", model: "dead"})
    Config.put_agent(%Agent{name: "sighted", model: "seer"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open(agent_name) do
    key = "web:upload-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, agent_name)
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    {view, key}
  end

  test "a text file is saved into the agent's workspace and its content rides into the turn" do
    {view, _key} = open("plain")

    upload =
      file_input(view, "#chat-compose", :attachment, [
        %{name: "notes.txt", content: "buy more coffee", type: "text/plain"}
      ])

    assert render_upload(upload, "notes.txt") =~ "notes.txt"

    view |> form("#chat-compose", %{"text" => "what does this say?"}) |> render_submit()

    html = render(view)
    assert html =~ "what does this say?"
    assert html =~ "buy more coffee"
    assert html =~ "notes.txt"
    assert html =~ "untrusted content the user attached"

    [saved] = Path.wildcard(Path.join([Pepe.Agent.Workspace.dir("plain"), "uploads", "*notes.txt"]))
    assert File.read!(saved) == "buy more coffee"
  end

  test "an unreadable file type still gets referenced by its saved path, not silently dropped" do
    {view, _key} = open("plain")

    upload =
      file_input(view, "#chat-compose", :attachment, [
        %{name: "archive.zip", content: <<0, 1, 2, 3>>, type: "application/zip"}
      ])

    render_upload(upload, "archive.zip")
    view |> form("#chat-compose", %{"text" => ""}) |> render_submit()

    html = render(view)
    assert html =~ "archive.zip"
    assert html =~ "be read as text directly"
  end

  test "an image on a vision-capable agent is not dumped as a raw text block" do
    {view, _key} = open("sighted")

    # A minimal valid 1x1 PNG.
    png =
      <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10,
        73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

    upload =
      file_input(view, "#chat-compose", :attachment, [
        %{name: "shot.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "shot.png")
    view |> form("#chat-compose", %{"text" => "describe this image"}) |> render_submit()

    html = render(view)
    assert html =~ "describe this image"
    assert html =~ "also attached"
    refute html =~ "--- Attached file: shot.png"

    [saved] = Path.wildcard(Path.join([Pepe.Agent.Workspace.dir("sighted"), "uploads", "*shot.png"]))
    assert File.read!(saved) == png
  end

  # No test for media.image.max_parts's cap here: Phoenix.LiveViewTest's simulated upload
  # channels don't support consuming more than one entry per turn in this version (a
  # pre-existing harness limitation, reproduced with plain multi-file text uploads too, not
  # specific to images or to this cap) - consume_uploaded_entries/3 raises
  # "GenServer.call(...) EXIT shutdown: :closed" regardless of what the entries are. The cap
  # itself (do_consume_attachments/4 in chat_live.ex) mirrors the exact pattern
  # lib/pepe/gateways/telegram.ex's own photo-album handling already uses in production.

  test "a slash command with a file staged is refused instead of being sent as literal text" do
    {view, key} = open("plain")

    upload = file_input(view, "#chat-compose", :attachment, [%{name: "notes.txt", content: "x", type: "text/plain"}])
    render_upload(upload, "notes.txt")

    html = view |> form("#chat-compose", %{"text" => "/name My chat"}) |> render_submit()

    refute html =~ "/name My chat"
    assert html =~ "Commands can&#39;t be combined"
    assert Pepe.Agent.SessionTitles.get(key) == nil
  end

  test "an oversized file no longer crashes the view when Send is pressed - it's dropped with a flash instead" do
    {view, _key} = open("plain")

    upload =
      file_input(view, "#chat-compose", :attachment, [
        %{name: "huge.bin", content: :binary.copy(<<0>>, 21_000_000), type: "application/octet-stream"}
      ])

    render_upload(upload, "huge.bin")
    # The per-entry error shows immediately, before Send is ever pressed.
    assert render(view) =~ "too big"

    html = view |> form("#chat-compose", %{"text" => "oi"}) |> render_submit()

    # The view is still alive and responsive - this used to raise ArgumentError inside
    # consume_uploaded_entries/3 and take the whole LiveView down with it.
    assert Process.alive?(view.pid)
    refute html =~ "huge.bin"
    assert html =~ "oi"
  end

  test "an oversized file's warning shows right after staging, not only on send" do
    {view, _key} = open("plain")

    upload =
      file_input(view, "#chat-compose", :attachment, [
        %{name: "huge.bin", content: :binary.copy(<<0>>, 21_000_000), type: "application/octet-stream"}
      ])

    render_upload(upload, "huge.bin")

    html = render(view)
    assert html =~ "huge.bin"
    assert html =~ "too big"
  end

  test "switching to a different chat in the same view drops a file staged but never sent" do
    {view, _key} = open("plain")

    upload = file_input(view, "#chat-compose", :attachment, [%{name: "left.txt", content: "x", type: "text/plain"}])
    render_upload(upload, "left.txt")
    assert render(view) =~ "left.txt"

    other_key = "web:upload-other-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(other_key, "plain")
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(other_key) end)

    html = view |> render_patch("/chat?chat=#{other_key}")
    refute html =~ "left.txt"
  end
end
