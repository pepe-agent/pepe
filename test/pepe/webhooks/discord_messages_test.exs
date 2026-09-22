defmodule Pepe.Webhooks.DiscordMessagesTest do
  @moduledoc """
  The half of Discord that is not a slash command: an ordinary message read off the gateway.

  What is under test is what makes a channel usable rather than merely connected. A message
  in a server is for the bot only when it is @mentioned or replied to, and a direct message
  always is. The bot's own mention must not stop `@bot /new` from being a command. Files come
  from the message, from the message it replies to, and from one that was forwarded. And a
  reply longer than Discord accepts arrives as several messages in order, rather than as the
  one that Discord would refuse whole.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Webhooks.Discord

  @bot "900"

  defp payload(d), do: %{"t" => "MESSAGE_CREATE", "d" => d, "bot_id" => @bot}

  defp message(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "m1",
        "type" => 0,
        "channel_id" => "C1",
        "guild_id" => "G1",
        "content" => "hello",
        "author" => %{"id" => "u1", "username" => "ana", "global_name" => "Ana"},
        "mentions" => [],
        "attachments" => []
      },
      overrides
    )
  end

  describe "parse/1 of a gateway message" do
    test "a channel message is addressed to the channel, from the person" do
      assert {:ok, [msg]} = Discord.parse(payload(message()))
      assert msg.from == "ch:C1"
      assert msg.sender_id == "u1"
      assert msg.name == "Ana"
      assert msg.text == "hello"
      assert msg.id == "m1"
      assert msg.media == []
    end

    test "the server nickname wins over the account name" do
      assert {:ok, [%{name: "Ana (ops)"}]} =
               Discord.parse(payload(message(%{"member" => %{"nick" => "Ana (ops)"}})))
    end

    test "the bot's own @mention is dropped so the rest can still be a command" do
      assert {:ok, [%{text: "/new"}]} = Discord.parse(payload(message(%{"content" => "<@#{@bot}> /new"})))
      assert {:ok, [%{text: "/new"}]} = Discord.parse(payload(message(%{"content" => "<@!#{@bot}>   /new"})))
    end

    test "somebody else's mention is part of what was said" do
      assert {:ok, [%{text: "<@42> hi"}]} = Discord.parse(payload(message(%{"content" => "<@42> hi"})))
    end

    test "an empty message with nothing attached is nothing to answer" do
      assert Discord.parse(payload(message(%{"content" => "  "}))) == :ignore
    end

    test "a voice message is an audio file that needs no caption" do
      voice = %{
        "url" => "https://cdn.discordapp.com/attachments/1/2/voice-message.ogg",
        "filename" => "voice-message.ogg",
        "content_type" => "audio/ogg",
        "size" => 5_000
      }

      assert {:ok, [msg]} = Discord.parse(payload(message(%{"content" => "", "attachments" => [voice], "flags" => 8192})))
      assert msg.text == ""
      assert [%{kind: "audio", ref: ref, mime: "audio/ogg", size: 5_000}] = msg.media
      assert ref == voice["url"]
    end

    test "each attachment keeps its own kind" do
      atts =
        for {name, type} <- [{"a.png", "image/png"}, {"b.pdf", "application/pdf"}, {"c.mp4", "video/mp4"}] do
          %{"url" => "https://cdn.discordapp.com/x/#{name}", "filename" => name, "content_type" => type, "size" => 1}
        end

      assert {:ok, [%{media: media}]} = Discord.parse(payload(message(%{"attachments" => atts})))
      assert Enum.map(media, & &1.kind) == ["image", "document", "video"]
    end

    test "files of the message being replied to and of a forwarded message count too" do
      own = %{"url" => "https://cdn.discordapp.com/own.png", "filename" => "own.png", "content_type" => "image/png"}
      replied = %{"url" => "https://cdn.discordapp.com/replied.pdf", "filename" => "replied.pdf", "content_type" => "application/pdf"}
      forwarded = %{"url" => "https://cdn.discordapp.com/fwd.ogg", "filename" => "fwd.ogg", "content_type" => "audio/ogg"}

      d =
        message(%{
          "attachments" => [own],
          "referenced_message" => %{"attachments" => [replied], "author" => %{"id" => "u2"}},
          "message_snapshots" => [%{"message" => %{"attachments" => [forwarded]}}]
        })

      assert {:ok, [%{media: media}]} = Discord.parse(payload(d))
      assert Enum.map(media, & &1.ref) == [own["url"], replied["url"], forwarded["url"]]
    end

    test "the same file mentioned twice is taken once" do
      att = %{"url" => "https://cdn.discordapp.com/one.png", "filename" => "one.png", "content_type" => "image/png"}
      d = message(%{"attachments" => [att], "referenced_message" => %{"attachments" => [att]}})

      assert {:ok, [%{media: [_only]}]} = Discord.parse(payload(d))
    end

    test "a picture sticker is a sticker file; a Lottie one, which has nothing to look at, is not" do
      d =
        message(%{
          "content" => "",
          "sticker_items" => [
            %{"id" => "111", "format_type" => 1},
            %{"id" => "222", "format_type" => 3},
            %{"id" => "333", "format_type" => 4},
            %{"id" => "../evil", "format_type" => 1}
          ]
        })

      assert {:ok, [%{media: media}]} = Discord.parse(payload(d))
      assert [%{kind: "sticker", mime: "image/png", ref: png}, %{kind: "sticker", mime: "image/gif", ref: gif}] = media
      assert png == "https://media.discordapp.net/stickers/111.png"
      assert gif == "https://media.discordapp.net/stickers/333.gif"
    end
  end

  describe "addressed?/2 of a gateway message" do
    test "a direct message always is" do
      assert Discord.addressed?(%{}, payload(message(%{"guild_id" => nil})))
    end

    test "a channel message is not, unless the bot is mentioned" do
      refute Discord.addressed?(%{}, payload(message()))
      assert Discord.addressed?(%{}, payload(message(%{"mentions" => [%{"id" => @bot}]})))
      refute Discord.addressed?(%{}, payload(message(%{"mentions" => [%{"id" => "42"}]})))
    end

    test "replying to something the bot said is addressing it" do
      d = message(%{"referenced_message" => %{"author" => %{"id" => @bot}}})
      assert Discord.addressed?(%{}, payload(d))

      d = message(%{"referenced_message" => %{"author" => %{"id" => "42"}}})
      refute Discord.addressed?(%{}, payload(d))
    end

    test "require_mention off opens the channel up" do
      config = %{"config" => %{"require_mention" => "false"}}
      assert Discord.addressed?(config, payload(message()))
    end

    test "a payload that names no bot is never mistaken for a mention" do
      d = message(%{"mentions" => [%{"username" => "someone"}]})
      refute Discord.addressed?(%{}, %{"t" => "MESSAGE_CREATE", "d" => d})
    end

    test "a slash command is addressed by definition" do
      assert Discord.addressed?(%{}, %{"type" => 2})
    end
  end

  describe "fetch_media/2" do
    test "a file over the connection's limit is refused before anything is downloaded" do
      reject = fn _url, _opts -> flunk("no download for a file that is too large") end
      stub(Pepe.Webhooks.Media.Download, :get, reject)

      media = %{kind: "document", ref: "https://cdn.discordapp.com/big.bin", size: 3 * 1_048_576}
      config = %{"config" => %{"max_attachment_mb" => "2"}}

      assert Discord.fetch_media(config, media) == {:error, :too_large}
    end

    test "only Discord's own CDN is ever asked, and at the connection's limit" do
      test = self()

      stub(Pepe.Webhooks.Media.Download, :get, fn url, opts ->
        send(test, {:get, url, opts})
        {:ok, "bytes"}
      end)

      media = %{kind: "document", ref: "https://cdn.discordapp.com/f.txt", size: 10}
      assert {:ok, "bytes"} = Discord.fetch_media(%{"config" => %{"max_attachment_mb" => "2"}}, media)

      assert_received {:get, "https://cdn.discordapp.com/f.txt", opts}
      assert opts[:hosts] == ["cdn.discordapp.com", "media.discordapp.net"]
      assert opts[:max_bytes] == 2 * 1_048_576
    end

    test "an address off the CDN is named as such" do
      media = %{kind: "document", ref: "https://evil.example/f.txt", size: 10}
      assert Discord.fetch_media(%{}, media) == {:error, :bad_attachment_url}
    end
  end

  describe "chunks/1" do
    test "a short reply is one message" do
      assert Discord.chunks("short") == ["short"]
    end

    test "a long reply is cut under the limit, at line breaks, losing nothing" do
      text = 1..300 |> Enum.map_join("\n", &"line number #{&1} of the reply")
      parts = Discord.chunks(text)

      assert match?([_, _ | _], parts)
      assert Enum.all?(parts, &(String.length(&1) <= 2000))
      assert Enum.join(parts, "\n") == text
    end

    test "text with no line break at all is still cut" do
      parts = Discord.chunks(String.duplicate("x", 5_000))
      assert Enum.all?(parts, &(String.length(&1) <= 2000))
      assert parts |> Enum.join() |> String.length() == 5_000
    end

    test "a code block a cut lands inside is closed and reopened, so both halves render" do
      code = 1..200 |> Enum.map_join("\n", &"  puts #{&1}")
      parts = Discord.chunks("```elixir\n" <> code <> "\n```")

      assert match?([_, _ | _], parts)

      for part <- parts do
        fences = part |> String.split("```") |> length() |> Kernel.-(1)
        assert rem(fences, 2) == 0, "unbalanced fence in: #{String.slice(part, -30, 30)}"
        assert String.length(part) <= 2000
      end
    end
  end

  describe "deliver/3 to a channel" do
    setup do
      test = self()

      stub(Req, :post, fn url, opts ->
        send(test, {:post, url, opts})
        {:ok, %{status: 200}}
      end)

      :ok
    end

    test "is posted with the bot's token and cannot ping anyone" do
      config = %{"config" => %{"bot_token" => "T0K"}}

      assert :ok = Discord.deliver(config, "ch:C1", "@everyone hello")

      assert_received {:post, "https://discord.com/api/v10/channels/C1/messages", opts}
      assert {"authorization", "Bot T0K"} in opts[:headers]
      assert opts[:json] == %{"content" => "@everyone hello", "allowed_mentions" => %{"parse" => []}}
    end

    test "the token may be written as an environment reference" do
      System.put_env("PEPE_TEST_DISCORD_TOKEN", "fromenv")
      on_exit(fn -> System.delete_env("PEPE_TEST_DISCORD_TOKEN") end)

      assert :ok = Discord.deliver(%{"config" => %{"bot_token" => "${PEPE_TEST_DISCORD_TOKEN}"}}, "ch:C1", "hi")
      assert_received {:post, _url, opts}
      assert {"authorization", "Bot fromenv"} in opts[:headers]
    end

    test "a long reply goes out as several messages, in order" do
      text = 1..300 |> Enum.map_join("\n", &"line #{&1} of the reply")

      assert :ok = Discord.deliver(%{"config" => %{"bot_token" => "T"}}, "ch:C1", text)

      sent = collect_posts([])
      assert match?([_, _ | _], sent)
      assert Enum.join(sent, "\n") == text
    end

    test "without a token it says so instead of guessing" do
      assert Discord.deliver(%{"config" => %{}}, "ch:C1", "hi") == {:error, :no_bot_token}
      refute_received {:post, _, _}
    end

    test "an error from Discord is returned, not swallowed" do
      stub(Req, :post, fn _url, _opts -> {:ok, %{status: 403, body: %{"message" => "Missing Access"}}} end)

      assert Discord.deliver(%{"config" => %{"bot_token" => "T"}}, "ch:C1", "hi") ==
               {:error, {:discord, 403, %{"message" => "Missing Access"}}}
    end

    test "a rate limit is waited out and the message sent once it lifts" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(Req, :post, fn _url, _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, %{status: 429, body: %{"retry_after" => 0.0}}}
          _ -> {:ok, %{status: 200}}
        end
      end)

      assert :ok = Discord.deliver(%{"config" => %{"bot_token" => "T"}}, "ch:C1", "hi")
      assert Agent.get(calls, & &1) == 2
    end

    test "a rate limit that never lifts gives up after a couple of tries" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(Req, :post, fn _url, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, %{status: 429, body: %{"retry_after" => 0}}}
      end)

      assert {:error, {:discord, 429, _}} = Discord.deliver(%{"config" => %{"bot_token" => "T"}}, "ch:C1", "hi")
      assert Agent.get(calls, & &1) == 3
    end
  end

  describe "deliver_file/4" do
    setup do
      path = Path.join(System.tmp_dir!(), "discord_file_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "contents")
      on_exit(fn -> File.rm(path) end)

      test = self()

      stub(Req, :post, fn url, opts ->
        send(test, {:post, url, opts})
        {:ok, %{status: 200}}
      end)

      %{path: path}
    end

    test "to a channel: a multipart upload with the bot's token that cannot ping anyone", %{path: path} do
      assert :ok = Discord.deliver_file(%{"config" => %{"bot_token" => "T0K"}}, "ch:C1", path, "here")

      assert_received {:post, "https://discord.com/api/v10/channels/C1/messages", opts}
      assert {"authorization", "Bot T0K"} in opts[:headers]
      assert :"files[0]" in Keyword.keys(opts[:form_multipart])

      payload = Jason.decode!(opts[:form_multipart][:payload_json])
      assert payload == %{"content" => "here", "allowed_mentions" => %{"parse" => []}}
    end

    test "to a channel, with no caption, still carries the mention guard", %{path: path} do
      assert :ok = Discord.deliver_file(%{"config" => %{"bot_token" => "T0K"}}, "ch:C1", path, nil)

      assert_received {:post, _url, opts}
      assert Jason.decode!(opts[:form_multipart][:payload_json]) == %{"allowed_mentions" => %{"parse" => []}}
    end

    test "without a token it says so", %{path: path} do
      assert Discord.deliver_file(%{"config" => %{}}, "ch:C1", path, nil) == {:error, :no_bot_token}
    end
  end

  describe "config_schema/0" do
    test "offers the gateway options, and only the token is a secret" do
      schema = Map.new(Discord.config_schema(), &{&1["key"], &1})

      assert schema["receive_channel_messages"]["type"] == "select"
      assert schema["bot_token"]["type"] == "secret"
      assert schema["require_mention"]["type"] == "select"
      assert schema["max_attachment_mb"]["type"] == "text"

      # Slash commands alone need neither, so a connection that only takes those can save.
      assert schema["bot_token"]["required"] == false
      assert schema["max_attachment_mb"]["required"] == false
    end
  end

  defp collect_posts(acc) do
    receive do
      {:post, _url, opts} -> collect_posts(acc ++ [opts[:json]["content"]])
    after
      0 -> acc
    end
  end
end
