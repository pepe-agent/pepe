defmodule Pepe.SendFileTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Tools.SendFile
  alias Pepe.Webhooks.Discord
  alias Pepe.Webhooks.Slack
  alias Pepe.Webhooks.WhatsApp

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_sendfile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    file = Path.join(home, "leads.xlsx")
    File.write!(file, "fake-xlsx-bytes")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{xlsx: file, home: home}
  end

  # ---- provider deliver_file/4 request shape ----------------------------------------

  # Slack's three-step upload: an upload url, the bytes, then the completion into the channel.
  defp stub_slack_upload(parent) do
    Mimic.stub(Req, :get, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true, "upload_url" => "https://files.slack.com/upload/v1/x", "file_id" => "F1"}}}
    end)

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)
  end

  test "discord sends the file as a multipart follow-up", %{xlsx: file} do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    assert :ok = Discord.deliver_file(%{"config" => %{"application_id" => "app1"}}, "tok", file, "here")
    assert_received {:req, "https://discord.com/api/v10/webhooks/app1/tok/messages", opts}
    keys = Keyword.keys(opts[:form_multipart])
    assert :"files[0]" in keys
    assert :payload_json in keys
  end

  test "slack uploads the file to the channel", %{xlsx: file} do
    stub_slack_upload(self())

    assert :ok = Slack.deliver_file(%{"config" => %{"bot_token" => "xoxb-1"}}, "C1", file, "here")
    assert_received {:req, "https://slack.com/api/files.getUploadURLExternal", get_opts}
    assert get_opts[:auth] == {:bearer, "xoxb-1"}
    assert_received {:req, "https://files.slack.com/upload/v1/x", _}
    assert_received {:req, "https://slack.com/api/files.completeUploadExternal", opts}
    assert opts[:json]["channel_id"] == "C1"
    assert opts[:json]["initial_comment"] == "here"
  end

  test "whatsapp uploads media then sends a document message", %{xlsx: file} do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      cond do
        String.ends_with?(url, "/media") ->
          send(parent, {:media, url, opts})
          {:ok, %{status: 200, body: %{"id" => "MEDIA123"}}}

        String.ends_with?(url, "/messages") ->
          send(parent, {:message, url, opts})
          {:ok, %{status: 200}}
      end
    end)

    config = %{"config" => %{"phone_number_id" => "999", "access_token" => "tok"}}
    assert :ok = WhatsApp.deliver_file(config, "5511", file, "here")

    assert_received {:media, url, _}
    assert url =~ "/999/media"
    assert_received {:message, _url, opts}
    assert opts[:json]["type"] == "document"
    assert opts[:json]["document"]["id"] == "MEDIA123"
    assert opts[:json]["document"]["caption"] == "here"
  end

  test "whatsapp sends a jpg/png as an image message, not a document, so it renders inline", %{home: home} do
    jpg = Path.join(home, "chart.jpg")
    File.write!(jpg, "fake-jpg-bytes")
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      cond do
        String.ends_with?(url, "/media") ->
          send(parent, {:media, url, opts})
          {:ok, %{status: 200, body: %{"id" => "MEDIA123"}}}

        String.ends_with?(url, "/messages") ->
          send(parent, {:message, url, opts})
          {:ok, %{status: 200}}
      end
    end)

    config = %{"config" => %{"phone_number_id" => "999", "access_token" => "tok"}}
    assert :ok = WhatsApp.deliver_file(config, "5511", jpg, "here")

    assert_received {:message, _url, opts}
    assert opts[:json]["type"] == "image"
    assert opts[:json]["image"]["id"] == "MEDIA123"
    assert opts[:json]["image"]["caption"] == "here"
  end

  # ---- the send_file tool routes to the session's channel ----------------------------

  test "send_file routes a Telegram session to sendDocument", %{xlsx: file} do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "telegram:842064390", cwd: Path.dirname(file)}
    assert {:ok, msg} = SendFile.run(%{"path" => Path.basename(file)}, ctx)
    assert msg =~ "leads.xlsx"
    assert_received {:req, url, _opts}
    assert url =~ "/sendDocument"
  end

  test "send_file routes a Telegram session to sendPhoto for a picture, so it renders inline instead of as a file attachment",
       %{home: home} do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    jpg = Path.join(home, "chart.png")
    File.write!(jpg, "fake-png-bytes")
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "telegram:842064390", cwd: home}
    assert {:ok, _msg} = SendFile.run(%{"path" => "chart.png"}, ctx)
    assert_received {:req, url, opts}
    assert url =~ "/sendPhoto"
    assert Keyword.has_key?(opts[:form_multipart], :photo)
  end

  test "send_file falls back to sendDocument when Telegram refuses the photo for a reason the size precheck can't catch",
       %{home: home} do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    jpg = Path.join(home, "weird.jpg")
    File.write!(jpg, "not actually a decodable image")
    parent = self()

    # Telegram rejects sendPhoto for reasons a size/extension precheck can never catch (an
    # extreme aspect ratio, a file that doesn't decode as an image at all) - the extension
    # alone said this should go as a photo, so the delivery must still succeed by retrying
    # as a plain document instead of failing outright.
    Mimic.stub(Req, :post, fn url, opts ->
      cond do
        String.ends_with?(url, "/sendPhoto") ->
          send(parent, {:req, url, opts})
          {:ok, %{status: 400, body: %{"ok" => false, "description" => "IMAGE_PROCESS_FAILED"}}}

        String.ends_with?(url, "/sendDocument") ->
          send(parent, {:req, url, opts})
          {:ok, %{status: 200}}
      end
    end)

    ctx = %{session_key: "telegram:842064390", cwd: home}
    assert {:ok, _msg} = SendFile.run(%{"path" => "weird.jpg"}, ctx)
    assert_received {:req, photo_url, _}
    assert photo_url =~ "/sendPhoto"
    assert_received {:req, doc_url, _}
    assert doc_url =~ "/sendDocument"
  end

  test "send_file still uses sendDocument for an image over Telegram's photo cap", %{home: home} do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    big_jpg = Path.join(home, "huge.jpg")
    File.write!(big_jpg, :binary.copy(<<0>>, 10 * 1024 * 1024 + 1))
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "telegram:842064390", cwd: home}
    assert {:ok, _msg} = SendFile.run(%{"path" => "huge.jpg"}, ctx)
    assert_received {:req, url, _opts}
    assert url =~ "/sendDocument"
  end

  test "send_file routes a Slack session to the bound connection", %{xlsx: file} do
    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})
    Config.put_webhook("team", %{"provider" => "slack", "agent" => "assistant", "config" => %{"bot_token" => "xoxb-9"}})
    stub_slack_upload(self())

    ctx = %{session_key: "slack:assistant:C42", cwd: Path.dirname(file)}
    assert {:ok, _} = SendFile.run(%{"path" => file}, ctx)
    assert_received {:req, "https://slack.com/api/files.completeUploadExternal", opts}
    assert opts[:json]["channel_id"] == "C42"
  end

  test "send_file on a dashboard session registers a download token and tells the chat about it", %{xlsx: file} do
    key = "web:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Pepe.PubSub, "session:" <> key)

    ctx = %{session_key: key, cwd: Path.dirname(file)}
    assert {:ok, msg} = SendFile.run(%{"path" => "leads.xlsx", "caption" => "here you go"}, ctx)
    assert msg =~ "leads.xlsx"

    assert_received {:session_event, ^key, {:file_ready, token, "leads.xlsx", "here you go"}}
    assert %{path: ^file, filename: "leads.xlsx"} = Pepe.Store.get(:dashboard_download, token)
  end

  test "send_file reports a clear error when the file is missing" do
    ctx = %{session_key: "telegram:1", cwd: System.tmp_dir!()}
    assert {:error, msg} = SendFile.run(%{"path" => "does-not-exist.xlsx"}, ctx)
    assert msg =~ "not found"
  end

  test "a relative path resolves against the agent's workspace, not the process cwd, when an agent is bound" do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    agent = %Config.Agent{name: "reportbot", system_prompt: "hi"}
    Config.put_agent(agent)

    workspace = Pepe.Agent.Workspace.dir(agent.name)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "leads.xlsx"), "fake-xlsx-bytes")

    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    # No `:cwd` at all - the process's own cwd (this test suite's directory) has no
    # leads.xlsx, so a pass here proves resolution used the workspace, not File.cwd!().
    ctx = %{session_key: "telegram:842064390", agent: agent}
    assert {:ok, msg} = SendFile.run(%{"path" => "leads.xlsx"}, ctx)
    assert msg =~ "leads.xlsx"
  end
end
