defmodule Pepe.Webhooks.SlackMediaTest do
  @moduledoc "A picture sent to the bot in Slack reaches the agent as media, not as lost text."
  use ExUnit.Case, async: true

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
end
