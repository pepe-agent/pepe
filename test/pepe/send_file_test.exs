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
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    assert :ok = Slack.deliver_file(%{"config" => %{"bot_token" => "xoxb-1"}}, "C1", file, "here")
    assert_received {:req, "https://slack.com/api/files.upload", opts}
    assert opts[:auth] == {:bearer, "xoxb-1"}
    assert opts[:form_multipart][:channels] == "C1"
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

  test "send_file routes a Slack session to the bound connection", %{xlsx: file} do
    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})
    Config.put_webhook("team", %{"provider" => "slack", "agent" => "assistant", "config" => %{"bot_token" => "xoxb-9"}})
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    ctx = %{session_key: "slack:assistant:C42", cwd: Path.dirname(file)}
    assert {:ok, _} = SendFile.run(%{"path" => file}, ctx)
    assert_received {:req, "https://slack.com/api/files.upload", opts}
    assert opts[:form_multipart][:channels] == "C42"
  end

  test "send_file reports a clear error when the file is missing" do
    ctx = %{session_key: "telegram:1", cwd: System.tmp_dir!()}
    assert {:error, msg} = SendFile.run(%{"path" => "does-not-exist.xlsx"}, ctx)
    assert msg =~ "not found"
  end
end
