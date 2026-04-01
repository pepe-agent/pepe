defmodule Pepe.Webhooks.MentionGatingTest do
  @moduledoc """
  Group/channel conversations should only reach the agent when the bot is actually
  addressed - mentioned, or the connection has opted out of the default gate. A 1:1
  conversation always reaches the agent regardless of the setting.
  """
  use ExUnit.Case, async: true

  alias Pepe.Webhooks.GoogleChat
  alias Pepe.Webhooks.MsTeams
  alias Pepe.Webhooks.Slack

  defp entry(require_mention \\ nil) do
    config = if require_mention, do: %{"require_mention" => require_mention}, else: %{}
    %{"config" => config}
  end

  describe "Slack" do
    test "app_mention is always addressed" do
      payload = %{"type" => "event_callback", "event" => %{"type" => "app_mention", "channel" => "C1"}}
      assert Slack.addressed?(entry(), payload)
    end

    test "a direct message (channel_type im) is always addressed" do
      payload = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "channel_type" => "im", "channel" => "D1"}
      }

      assert Slack.addressed?(entry(), payload)
    end

    test "a plain channel message is not addressed by default" do
      payload = %{"type" => "event_callback", "event" => %{"type" => "message", "channel" => "C1"}}
      refute Slack.addressed?(entry(), payload)
    end

    test "a plain channel message is addressed when require_mention is off" do
      payload = %{"type" => "event_callback", "event" => %{"type" => "message", "channel" => "C1"}}
      assert Slack.addressed?(entry("false"), payload)
    end

    test "a DM-shaped channel id (D-prefixed) is addressed even without channel_type" do
      payload = %{"type" => "event_callback", "event" => %{"type" => "message", "channel" => "D1"}}
      assert Slack.addressed?(entry(), payload)
    end

    test "a non-message payload (e.g. url_verification) is not gated here" do
      assert Slack.addressed?(entry(), %{"type" => "url_verification"})
    end
  end

  describe "MS Teams" do
    test "a personal (1:1) chat is always addressed" do
      activity = %{"type" => "message", "conversation" => %{"conversationType" => "personal"}}
      assert MsTeams.addressed?(entry(), activity)
    end

    test "a channel message with no mention entity is not addressed by default" do
      activity = %{"type" => "message", "conversation" => %{"conversationType" => "channel"}, "entities" => []}
      refute MsTeams.addressed?(entry(), activity)
    end

    test "a channel message mentioning the bot's recipient id is addressed" do
      activity = %{
        "type" => "message",
        "conversation" => %{"conversationType" => "channel"},
        "recipient" => %{"id" => "bot-1"},
        "entities" => [%{"type" => "mention", "mentioned" => %{"id" => "bot-1"}}]
      }

      assert MsTeams.addressed?(entry(), activity)
    end

    test "a mention entity for someone else does not address the bot" do
      activity = %{
        "type" => "message",
        "conversation" => %{"conversationType" => "channel"},
        "recipient" => %{"id" => "bot-1"},
        "entities" => [%{"type" => "mention", "mentioned" => %{"id" => "someone-else"}}]
      }

      refute MsTeams.addressed?(entry(), activity)
    end

    test "a channel message is addressed when require_mention is off" do
      activity = %{"type" => "message", "conversation" => %{"conversationType" => "channel"}, "entities" => []}
      assert MsTeams.addressed?(entry("false"), activity)
    end
  end

  describe "Google Chat" do
    test "a DM space is always addressed" do
      payload = %{"type" => "MESSAGE", "message" => %{}, "space" => %{"type" => "DM"}}
      assert GoogleChat.addressed?(entry(), payload)
    end

    test "a multi-person space message with no mention is not addressed by default" do
      payload = %{"type" => "MESSAGE", "message" => %{}, "space" => %{"type" => "ROOM"}}
      refute GoogleChat.addressed?(entry(), payload)
    end

    test "a multi-person space message that mentions the app is addressed" do
      payload = %{
        "type" => "MESSAGE",
        "message" => %{
          "annotations" => [%{"type" => "USER_MENTION", "userMention" => %{"user" => %{"name" => "users/app"}}}]
        },
        "space" => %{"type" => "ROOM"}
      }

      assert GoogleChat.addressed?(entry(), payload)
    end

    test "a mention of a different user does not address the app" do
      payload = %{
        "type" => "MESSAGE",
        "message" => %{
          "annotations" => [%{"type" => "USER_MENTION", "userMention" => %{"user" => %{"name" => "users/123"}}}]
        },
        "space" => %{"type" => "ROOM"}
      }

      refute GoogleChat.addressed?(entry(), payload)
    end

    test "a multi-person space message is addressed when require_mention is off" do
      payload = %{"type" => "MESSAGE", "message" => %{}, "space" => %{"type" => "ROOM"}}
      assert GoogleChat.addressed?(entry("false"), payload)
    end
  end
end
