defmodule Pepe.Webhooks.MentionGatingTest do
  @moduledoc """
  Group/channel conversations should only reach the agent when the bot is actually
  addressed - mentioned. A 1:1 conversation always reaches the agent. Whether a channel answers
  without a mention is the channel's own `/mention` setting, applied by Pepe.Webhooks.
  """
  use ExUnit.Case, async: true

  alias Pepe.Webhooks.GoogleChat
  alias Pepe.Webhooks.MsTeams
  alias Pepe.Webhooks.Slack

  defp entry, do: %{"config" => %{}}

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

    test "a DM-shaped channel id (D-prefixed) is addressed even without channel_type" do
      payload = %{"type" => "event_callback", "event" => %{"type" => "message", "channel" => "D1"}}
      assert Slack.addressed?(entry(), payload)
    end

    test "a non-message payload (e.g. url_verification) is not gated here" do
      assert Slack.addressed?(entry(), %{"type" => "url_verification"})
    end

    test "parse/1 strips a leading space, so ' /mention off' still reaches command/3 as a command" do
      # Slack's own client intercepts anything starting with "/" as an attempted slash command
      # and refuses to send it at all unless one is registered under that name - typing a
      # leading space is how Slack itself tells someone to get a literal message through.
      # Pepe's docs point people at that workaround, so this is what makes it actually work:
      # parse/1 must hand command/3 a string starting with "/", not " /".
      payload = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "channel" => "C1", "text" => " /mention off", "ts" => "1.1"}
      }

      assert {:ok, [%{text: "/mention off"}]} = Slack.parse(payload)
    end
  end

  describe "Slack: a message written to someone else" do
    defp channel_text(text, event \\ %{}) do
      %{
        "type" => "event_callback",
        "authorizations" => [%{"user_id" => "UBOT"}],
        "event" => Map.merge(%{"type" => "message", "channel" => "C1", "text" => text, "ts" => "1.1"}, event)
      }
    end

    test "tagging a person without the bot is for that person" do
      assert Slack.directed_elsewhere?(entry(), channel_text("<@UGIAN> can I reopen the card?"))
      assert Slack.directed_elsewhere?(entry(), channel_text("<@UGIAN|gian> can I reopen the card?"))
    end

    test "a group or the whole channel counts as someone else too" do
      for tag <- ["<!subteam^S123>", "<!channel>", "<!here>", "<!everyone>"] do
        assert Slack.directed_elsewhere?(entry(), channel_text("#{tag} heads up")), tag
      end
    end

    test "tagging the bot, alone or with others, is for the bot" do
      refute Slack.directed_elsewhere?(entry(), channel_text("<@UBOT> can I reopen the card?"))
      refute Slack.directed_elsewhere?(entry(), channel_text("<@UGIAN> <@UBOT> can I reopen the card?"))
    end

    test "no tag at all is not directed elsewhere" do
      refute Slack.directed_elsewhere?(entry(), channel_text("can I reopen the card?"))
    end

    test "a direct message is never directed elsewhere" do
      refute Slack.directed_elsewhere?(entry(), channel_text("<@UGIAN> hi", %{"channel" => "D1", "channel_type" => "im"}))
    end

    test "a message from another app is exempt, since a help desk card may name people" do
      refute Slack.directed_elsewhere?(entry(), channel_text("<@UGIAN> new ticket", %{"bot_id" => "B1", "subtype" => "bot_message"}))
    end

    test "without the bot's own user id in the payload, nothing is skipped" do
      payload = channel_text("<@UGIAN> hi") |> Map.delete("authorizations")
      refute Slack.directed_elsewhere?(entry(), payload)
    end

    test "other payload types are not directed elsewhere" do
      refute Slack.directed_elsewhere?(entry(), %{"type" => "url_verification"})
    end
  end

  describe "other channels: a message written to someone else" do
    alias Pepe.Webhooks.Discord

    defp discord(d, bot \\ "BOT") do
      %{
        "t" => "MESSAGE_CREATE",
        "bot_id" => bot,
        "d" => Map.merge(%{"guild_id" => "G1", "content" => "hi", "author" => %{"id" => "P1"}}, d)
      }
    end

    test "Discord: a person, a role or everyone without the bot is for them" do
      assert Discord.directed_elsewhere?(entry(), discord(%{"mentions" => [%{"id" => "GIAN"}]}))
      assert Discord.directed_elsewhere?(entry(), discord(%{"mention_roles" => ["R1"]}))
      assert Discord.directed_elsewhere?(entry(), discord(%{"mention_everyone" => true}))
    end

    test "Discord: the bot tagged or replied to, no tag, a DM or another bot are not" do
      refute Discord.directed_elsewhere?(entry(), discord(%{"mentions" => [%{"id" => "GIAN"}, %{"id" => "BOT"}]}))
      refute Discord.directed_elsewhere?(entry(), discord(%{"mentions" => [%{"id" => "BOT"}]}))

      refute Discord.directed_elsewhere?(
               entry(),
               discord(%{"mentions" => [%{"id" => "GIAN"}], "referenced_message" => %{"author" => %{"id" => "BOT"}}})
             )

      refute Discord.directed_elsewhere?(entry(), discord(%{}))
      refute Discord.directed_elsewhere?(entry(), discord(%{"guild_id" => nil, "mentions" => [%{"id" => "GIAN"}]}))
      refute Discord.directed_elsewhere?(entry(), discord(%{"mentions" => [%{"id" => "GIAN"}], "author" => %{"bot" => true}}))
    end

    defp teams(entities, type \\ "channel") do
      %{"type" => "message", "recipient" => %{"id" => "BOT"}, "conversation" => %{"conversationType" => type}, "entities" => entities}
    end

    defp tag(id), do: %{"type" => "mention", "mentioned" => %{"id" => id}}

    test "Teams: a mention of anyone but the bot is for them" do
      assert MsTeams.directed_elsewhere?(entry(), teams([tag("GIAN")]))
      refute MsTeams.directed_elsewhere?(entry(), teams([tag("GIAN"), tag("BOT")]))
      refute MsTeams.directed_elsewhere?(entry(), teams([]))
      refute MsTeams.directed_elsewhere?(entry(), teams([tag("GIAN")], "personal"))
    end

    defp gchat(annotations, space \\ "SPACE", sender \\ "HUMAN") do
      %{
        "type" => "MESSAGE",
        "space" => %{"type" => space},
        "message" => %{"sender" => %{"type" => sender}, "annotations" => annotations}
      }
    end

    defp gmention(name), do: %{"type" => "USER_MENTION", "userMention" => %{"user" => %{"name" => name}}}

    test "Google Chat: a mention of anyone but the app is for them" do
      assert GoogleChat.directed_elsewhere?(entry(), gchat([gmention("users/123")]))
      refute GoogleChat.directed_elsewhere?(entry(), gchat([gmention("users/123"), gmention("users/app")]))
      refute GoogleChat.directed_elsewhere?(entry(), gchat([]))
      refute GoogleChat.directed_elsewhere?(entry(), gchat([gmention("users/123")], "DM"))
      refute GoogleChat.directed_elsewhere?(entry(), gchat([gmention("users/123")], "SPACE", "BOT"))
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
  end
end
