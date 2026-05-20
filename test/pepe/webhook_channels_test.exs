defmodule Pepe.WebhookChannelsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Webhooks.Discord
  alias Pepe.Webhooks.GoogleChat
  alias Pepe.Webhooks.MsTeams
  alias Pepe.Webhooks.Slack
  alias Pepe.Webhooks.WhatsApp

  describe "slack" do
    test "answers the url_verification challenge synchronously" do
      assert {:reply, 200, "text/plain", "abc123"} =
               Slack.respond(%{}, %{"type" => "url_verification", "challenge" => "abc123"}, %{})
    end

    test "parses a user message and ignores bot echoes and edits" do
      event = %{"type" => "event_callback", "event" => %{"type" => "message", "text" => "hi", "channel" => "C1", "ts" => "1.2"}}
      assert {:ok, [%{from: "C1", text: "hi", id: "1.2"}]} = Slack.parse(event)

      bot = put_in(event["event"]["bot_id"], "B1")
      assert :ignore = Slack.parse(bot)

      edit = put_in(event["event"]["subtype"], "message_changed")
      assert :ignore = Slack.parse(edit)
    end

    test "verifies the request signature" do
      secret = "shhh"
      body = ~s({"type":"event_callback"})
      # A fresh timestamp: Slack signs it, and stale ones are now rejected as replays.
      ts = Integer.to_string(System.system_time(:second))
      sig = "v0=" <> (:crypto.mac(:hmac, :sha256, secret, "v0:#{ts}:#{body}") |> Base.encode16(case: :lower))
      config = %{"config" => %{"signing_secret" => secret}}
      headers = %{"x-slack-request-timestamp" => ts, "x-slack-signature" => sig}

      assert :ok = Slack.authenticate(config, body, headers)
      assert :error = Slack.authenticate(config, body, %{headers | "x-slack-signature" => "v0=deadbeef"})
    end

    test "delivers via chat.postMessage" do
      parent = self()

      Mimic.stub(Req, :post, fn url, opts ->
        send(parent, {:req, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      assert :ok = Slack.deliver(%{"config" => %{"bot_token" => "xoxb-1"}}, "C1", "yo")
      assert_received {:req, "https://slack.com/api/chat.postMessage", opts}
      assert opts[:json] == %{"channel" => "C1", "text" => "yo"}
    end
  end

  describe "discord" do
    test "PING gets a PONG; a command gets a deferred ack that still runs the agent" do
      assert {:reply, 200, "application/json", ~s({"type":1})} = Discord.respond(%{}, %{"type" => 1}, %{})
      assert {:reply_async, 200, "application/json", ~s({"type":5})} = Discord.respond(%{}, %{"type" => 2}, %{})
    end

    test "parses a slash command's option value, addressed by the interaction token" do
      p = %{
        "type" => 2,
        "id" => "9",
        "token" => "tok",
        "data" => %{"name" => "ask", "options" => [%{"name" => "prompt", "value" => "hello"}]}
      }

      assert {:ok, [%{from: "tok", text: "hello", id: "9"}]} = Discord.parse(p)
    end

    test "verifies the Ed25519 signature over timestamp+body" do
      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      body = ~s({"type":1})
      ts = "1700"
      sig = :crypto.sign(:eddsa, :none, "#{ts}#{body}", [priv, :ed25519]) |> Base.encode16(case: :lower)
      config = %{"config" => %{"public_key" => Base.encode16(pub, case: :lower)}}
      headers = %{"x-signature-ed25519" => sig, "x-signature-timestamp" => ts}

      assert :ok = Discord.authenticate(config, body, headers)
      assert :error = Discord.authenticate(config, "tampered", headers)
    end

    test "delivers a follow-up to the interaction webhook" do
      parent = self()

      Mimic.stub(Req, :post, fn url, opts ->
        send(parent, {:req, url, opts})
        {:ok, %{status: 200}}
      end)

      assert :ok = Discord.deliver(%{"config" => %{"application_id" => "app1"}}, "tok", "answer")
      assert_received {:req, "https://discord.com/api/v10/webhooks/app1/tok/messages", opts}
      assert opts[:json] == %{"content" => "answer"}
    end
  end

  describe "google chat" do
    test "parses a human MESSAGE and ignores bot senders" do
      msg = %{
        "type" => "MESSAGE",
        "space" => %{"name" => "spaces/AAA"},
        "message" => %{"text" => "hey", "sender" => %{"type" => "HUMAN"}, "name" => "m1"}
      }

      assert {:ok, [%{from: "spaces/AAA", text: "hey"}]} = GoogleChat.parse(msg)

      bot = put_in(msg["message"]["sender"]["type"], "BOT")
      assert :ignore = GoogleChat.parse(bot)
    end
  end

  describe "teams" do
    test "parses a message activity and strips the bot mention" do
      activity = %{
        "type" => "message",
        "text" => "<at>Bot</at> hello there",
        "serviceUrl" => "https://sf.example/",
        "conversation" => %{"id" => "c1"},
        "id" => "a1"
      }

      assert {:ok, [%{from: "https://sf.example/|c1", text: "hello there"}]} = MsTeams.parse(activity)
    end

    test "ignores the bot's own activities" do
      bot = %{
        "type" => "message",
        "text" => "hi",
        "serviceUrl" => "https://x/",
        "conversation" => %{"id" => "c"},
        "from" => %{"role" => "bot"}
      }

      assert :ignore = MsTeams.parse(bot)
    end

    test "mints a token then posts the reply to the serviceUrl" do
      parent = self()

      Mimic.stub(Req, :post, fn url, opts ->
        if String.contains?(url, "login.microsoftonline.com") do
          send(parent, {:token_req, opts[:form]})
          {:ok, %{status: 200, body: %{"access_token" => "T"}}}
        else
          send(parent, {:activity_req, url, opts})
          {:ok, %{status: 200}}
        end
      end)

      # `sf.example` isn't a public Bot Framework host, so the connection allows it explicitly
      # (as a regional/self-hosted deployment would for its own service host).
      config = %{"config" => %{"app_id" => "id", "app_password" => "sec", "tenant_id" => "ten", "service_hosts" => ["sf.example"]}}
      assert :ok = MsTeams.deliver(config, "https://sf.example/|conv1", "reply")

      assert_received {:token_req, form}
      assert form["client_id"] == "id"
      assert_received {:activity_req, "https://sf.example/v3/conversations/conv1/activities", opts}
      assert opts[:json]["text"] == "reply"
      assert opts[:auth] == {:bearer, "T"}
    end
  end

  describe "whatsapp" do
    test "verifies the subscribe handshake" do
      config = %{"config" => %{"verify_token" => "vt"}}
      assert {:ok, "chal"} = WhatsApp.verify(config, %{"hub.verify_token" => "vt", "hub.challenge" => "chal"})
      assert :error = WhatsApp.verify(config, %{"hub.verify_token" => "nope", "hub.challenge" => "chal"})
    end

    test "checks the X-Hub signature when an app secret is set" do
      secret = "sek"
      body = ~s({"x":1})
      sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
      config = %{"config" => %{"app_secret" => secret}}

      assert :ok = WhatsApp.authenticate(config, body, %{"x-hub-signature-256" => sig})
      assert :error = WhatsApp.authenticate(config, body, %{"x-hub-signature-256" => "sha256=bad"})
    end

    test "parses a text message and ignores everything else" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{"value" => %{"messages" => [%{"from" => "5511", "type" => "text", "text" => %{"body" => "oi"}, "id" => "wamid"}]}}
            ]
          }
        ]
      }

      assert {:ok, [%{from: "5511", text: "oi", id: "wamid"}]} = WhatsApp.parse(payload)
      assert :ignore = WhatsApp.parse(%{"entry" => []})
    end

    test "delivers to the Graph API" do
      parent = self()

      Mimic.stub(Req, :post, fn url, opts ->
        send(parent, {:req, url, opts})
        {:ok, %{status: 200}}
      end)

      config = %{"config" => %{"access_token" => "tok", "phone_number_id" => "999"}}
      assert :ok = WhatsApp.deliver(config, "5511", "hey")
      assert_received {:req, url, opts}
      assert url =~ "/999/messages"
      assert opts[:json]["to"] == "5511"
    end
  end

  describe "google chat deliver" do
    test "posts to the space via the Chat API" do
      parent = self()

      Mimic.stub(Req, :post, fn url, opts ->
        send(parent, {:req, url, opts})
        {:ok, %{status: 200}}
      end)

      assert :ok = GoogleChat.deliver(%{"config" => %{"access_token" => "T"}}, "spaces/AAA", "hi")
      assert_received {:req, "https://chat.googleapis.com/v1/spaces/AAA/messages", opts}
      assert opts[:json] == %{"text" => "hi"}
      assert opts[:auth] == {:bearer, "T"}
    end
  end

  test "every built-in provider satisfies the Provider contract and has a sane schema" do
    for name <- ~w(whatsapp slack discord msteams googlechat) do
      mod = Pepe.Webhooks.provider(name)
      assert mod, "#{name} is not registered"
      assert mod.name() == name

      for {fun, arity} <- [{:verify, 2}, {:authenticate, 3}, {:parse, 1}, {:deliver, 3}] do
        assert function_exported?(mod, fun, arity), "#{name} is missing #{fun}/#{arity}"
      end

      if function_exported?(mod, :config_schema, 0) do
        for field <- mod.config_schema() do
          assert is_binary(field["key"]) and field["key"] != ""
          assert is_binary(field["label"])
          assert field["type"] in ["text", "secret", "select"]
        end
      end
    end
  end

  test "the gateway returns a synchronous response when a provider asks for one" do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_ch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Slack signs the url_verification handshake too, so the connection carries a secret and the
    # request is signed - the same fail-closed authentication as any other inbound.
    secret = "shhh"
    Pepe.Config.put_webhook("s1", %{"provider" => "slack", "company" => nil, "agent" => "x", "config" => %{"signing_secret" => secret}})
    payload = %{"type" => "url_verification", "challenge" => "ok!"}
    raw = ~s({"type":"url_verification","challenge":"ok!"})
    ts = Integer.to_string(System.system_time(:second))
    sig = "v0=" <> (:crypto.mac(:hmac, :sha256, secret, "v0:#{ts}:#{raw}") |> Base.encode16(case: :lower))
    headers = %{"x-slack-request-timestamp" => ts, "x-slack-signature" => sig}

    assert {:respond, 200, "text/plain", "ok!"} =
             Pepe.Webhooks.handle_inbound("root", "slack", "s1", raw, payload, headers)
  end
end
