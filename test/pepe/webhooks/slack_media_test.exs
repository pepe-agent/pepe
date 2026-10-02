defmodule Pepe.Webhooks.SlackMediaTest do
  @moduledoc "A picture sent to the bot in Slack reaches the agent as media, not as lost text."
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Webhooks.Slack

  defp event(overrides) do
    %{
      "type" => "event_callback",
      "event" =>
        Map.merge(
          %{"type" => "app_mention", "channel" => "C1", "ts" => "1.1", "text" => "<@U1> is this it?"},
          overrides
        )
    }
  end

  @file_share %{
    "name" => "image.png",
    "mimetype" => "image/png",
    "size" => 1234,
    "url_private_download" => "https://files.slack.com/files-pri/T-F/download/image.png"
  }

  test "a mention with an attached image carries it as media" do
    assert {:ok, [msg]} = Slack.parse(event(%{"files" => [@file_share]}))
    assert msg.text == "is this it?"
    assert [%{kind: "image", ref: "https://files.slack.com/" <> _, filename: "image.png", size: 1234}] = msg.media
  end

  test "a file_share message with no text is still a message" do
    payload = event(%{"type" => "message", "subtype" => "file_share", "text" => "", "files" => [@file_share]})
    assert {:ok, [%{text: "", media: [%{kind: "image"}]}]} = Slack.parse(payload)
  end

  test "other subtypes and empty messages are still ignored" do
    assert :ignore = Slack.parse(event(%{"subtype" => "message_changed"}))
    assert :ignore = Slack.parse(event(%{"text" => ""}))
  end

  test "fetch_media refuses a url that is not Slack's file host" do
    config = %{"config" => %{"bot_token" => "xoxb-test"}}
    assert {:error, :bad_attachment_url} = Slack.fetch_media(config, %{kind: "image", ref: "https://evil.example/x.png"})
  end

  describe "deliver_file/4" do
    @config %{"config" => %{"bot_token" => "xoxb-test"}}

    setup do
      path = Path.join(System.tmp_dir!(), "slack_media_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "hello")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "asks for an upload url, sends the bytes, then completes into the channel", %{path: path} do
      test = self()

      stub(Req, :get, fn "https://slack.com/api/files.getUploadURLExternal", opts ->
        send(test, {:get, opts[:params]})
        {:ok, %{status: 200, body: %{"ok" => true, "upload_url" => "https://files.slack.com/upload/v1/x", "file_id" => "F1"}}}
      end)

      stub(Req, :post, fn
        "https://files.slack.com/upload/v1/x", opts ->
          send(test, {:bytes, opts[:body]})
          {:ok, %{status: 200, body: "OK"}}

        "https://slack.com/api/files.completeUploadExternal", opts ->
          send(test, {:complete, opts[:json]})
          {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      assert :ok = Slack.deliver_file(@config, "C1", path, "here you go")

      assert_received {:get, params}
      assert params[:length] == 5
      assert_received {:bytes, "hello"}
      assert_received {:complete, %{"channel_id" => "C1", "initial_comment" => "here you go", "files" => [%{"id" => "F1"}]}}
    end

    test "a refused upload url is an error, not a silent success", %{path: path} do
      stub(Req, :get, fn _url, _opts -> {:ok, %{status: 200, body: %{"ok" => false, "error" => "missing_scope"}}} end)
      assert {:error, {:slack, 200, %{"error" => "missing_scope"}}} = Slack.deliver_file(@config, "C1", path, nil)
    end
  end

  describe "working/3" do
    @config %{"config" => %{"bot_token" => "xoxb-test"}}

    test "adds an eyes reaction to the message when the agent starts and removes it when done" do
      test = self()

      stub(Req, :post, fn url, opts ->
        send(test, {:post, url, opts[:json]})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      message = %{from: "C1", id: "1.1"}
      assert :ok = Slack.working(@config, message, :start)
      assert_received {:post, "https://slack.com/api/reactions.add", %{"channel" => "C1", "timestamp" => "1.1", "name" => "eyes"}}

      assert :ok = Slack.working(@config, message, :stop)
      assert_received {:post, "https://slack.com/api/reactions.remove", %{"timestamp" => "1.1"}}
    end

    test "a refused reaction (missing scope) is an error value, never a crash" do
      stub(Req, :post, fn _url, _opts -> {:ok, %{status: 200, body: %{"ok" => false, "error" => "missing_scope"}}} end)
      assert {:error, {:slack, 200, _}} = Slack.working(@config, %{from: "C1", id: "1.1"}, :start)
    end
  end

  describe "reactions" do
    defp reaction(overrides \\ %{}) do
      %{
        "type" => "event_callback",
        "authorizations" => [%{"user_id" => "UBOT"}],
        "event" =>
          Map.merge(
            %{
              "type" => "reaction_added",
              "user" => "UANA",
              "reaction" => "+1",
              "item" => %{"type" => "message", "channel" => "C1", "ts" => "5.5"},
              "item_user" => "UBOT",
              "event_ts" => "6.6"
            },
            overrides
          )
      }
    end

    test "a thumbs up on the bot's own message reaches the agent as feedback" do
      assert {:ok, [%{from: "C1", text: "[reacted 👍]", id: "6.6"}]} = Slack.parse(reaction())
    end

    test "a skin tone or an unknown name still reads sensibly" do
      assert {:ok, [%{text: "[reacted 👍]"}]} = Slack.parse(reaction(%{"reaction" => "+1::skin-tone-3"}))
      assert {:ok, [%{text: "[reacted :party_parrot:]"}]} = Slack.parse(reaction(%{"reaction" => "party_parrot"}))
    end

    test "a reaction on someone else's message, or by the bot itself, is dropped" do
      assert :ignore = Slack.parse(reaction(%{"item_user" => "UANA"}))
      assert :ignore = Slack.parse(reaction(%{"user" => "UBOT"}))
    end

    test "without the bot's id in the payload nothing is delivered" do
      assert :ignore = Slack.parse(Map.delete(reaction(), "authorizations"))
    end

    test "reactions: off stops them being answered, no mention needed otherwise" do
      assert Slack.addressed?(%{"config" => %{}}, reaction())
      refute Slack.addressed?(%{"config" => %{"reactions" => "off"}}, reaction())
    end
  end
end
