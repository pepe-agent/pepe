defmodule Pepe.WebhooksTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Webhooks
  alias Pepe.Webhooks.WhatsApp

  # A minimal chat-completions mock, for round-tripping a real Session.chat/2 call:
  # the actual model request happens deep inside the session's own
  # (DynamicSupervisor-started) process and its internally spawned run task,
  # neither of which inherit this test process's Mimic stubs (private mode only
  # covers a call's own $callers chain) - so it needs a real HTTP server, not Req
  # mocking, the same way test/pepe/agent/session_model_override_test.exs does.
  defmodule FixedReplyPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, reply: reply) do
      payload = %{
        "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => reply}, "finish_reason" => "stop"}]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_wh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    # Registered last so it runs FIRST: a run still in flight has to be stopped while the config
    # and PEPE_HOME it is running against still exist, or it carries on into the next test and
    # calls that test's mock. See Pepe.Test.Sessions.
    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    :ok
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "provider" => "whatsapp",
        "project" => "acme",
        "agent" => "acme/support",
        "mode" => "support",
        "config" => %{
          "phone_number_id" => "123",
          "access_token" => "tok",
          "app_secret" => "s3cr3t",
          "verify_token" => "vt"
        }
      },
      overrides
    )
  end

  describe "WhatsApp provider" do
    test "verify echoes the challenge only when the token matches" do
      e = entry()

      assert {:ok, "42"} =
               WhatsApp.verify(e, %{"hub.verify_token" => "vt", "hub.challenge" => "42"})

      assert :error =
               WhatsApp.verify(e, %{"hub.verify_token" => "wrong", "hub.challenge" => "42"})
    end

    test "authenticate validates the HMAC-SHA256 signature over the raw body" do
      e = entry()
      body = ~s({"hello":"world"})

      sig =
        "sha256=" <> (:crypto.mac(:hmac, :sha256, "s3cr3t", body) |> Base.encode16(case: :lower))

      assert :ok = WhatsApp.authenticate(e, body, %{"x-hub-signature-256" => sig})

      assert :error =
               WhatsApp.authenticate(e, body, %{"x-hub-signature-256" => "sha256=deadbeef"})

      assert :error = WhatsApp.authenticate(e, body, %{})
    end

    test "parse extracts text and media messages, and ignores the rest" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "5511999",
                      "type" => "text",
                      "text" => %{"body" => "oi"},
                      "id" => "m1"
                    },
                    %{"from" => "5511999", "type" => "image", "image" => %{"id" => "x"}},
                    %{"from" => "5511999", "type" => "reaction", "reaction" => %{"emoji" => "👍"}}
                  ]
                }
              }
            ]
          }
        ]
      }

      # The image is a message too - described here, fetched later (see
      # test/pepe/webhooks/media_test.exs). A reaction still isn't one.
      assert {:ok, [text, image]} = WhatsApp.parse(payload)
      assert %{from: "5511999", text: "oi", id: "m1"} = text
      assert %{text: "", media: %{kind: "image", ref: "x"}} = image

      assert :ignore =
               WhatsApp.parse(%{"entry" => [%{"changes" => [%{"value" => %{"statuses" => []}}]}]})
    end

    test "parse carries the sender's profile name from contacts, matched by wa_id" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "contacts" => [%{"wa_id" => "5511999", "profile" => %{"name" => "Maria"}}],
                  "messages" => [%{"from" => "5511999", "type" => "text", "text" => %{"body" => "oi"}, "id" => "m1"}]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, [%{name: "Maria"}]} = WhatsApp.parse(payload)
    end

    test "parse leaves name nil when the payload carries no contacts entry" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{"value" => %{"messages" => [%{"from" => "5511999", "type" => "text", "text" => %{"body" => "oi"}, "id" => "m1"}]}}
            ]
          }
        ]
      }

      assert {:ok, [%{name: nil}]} = WhatsApp.parse(payload)
    end
  end

  describe "Google Chat provider" do
    test "parse carries the sender's displayName" do
      payload = %{
        "type" => "MESSAGE",
        "space" => %{"name" => "spaces/AAA"},
        "message" => %{
          "text" => "oi",
          "name" => "spaces/AAA/messages/m1",
          "sender" => %{"type" => "HUMAN", "displayName" => "Maria"}
        }
      }

      assert {:ok, [%{from: "spaces/AAA", text: "oi", name: "Maria"}]} = Pepe.Webhooks.GoogleChat.parse(payload)
    end
  end

  describe "MS Teams provider" do
    test "parse carries the sender's name from the activity's from field" do
      activity = %{
        "type" => "message",
        "text" => "oi",
        "id" => "a1",
        "serviceUrl" => "https://smba.example.com",
        "conversation" => %{"id" => "c1"},
        "from" => %{"id" => "29:abc", "name" => "Maria"}
      }

      assert {:ok, [%{text: "oi", name: "Maria"}]} = Pepe.Webhooks.MsTeams.parse(activity)
    end
  end

  describe "Discord provider" do
    test "parse carries the invoking member's username in a guild" do
      payload = %{
        "type" => 2,
        "token" => "tok",
        "id" => "i1",
        "data" => %{"name" => "ask", "options" => [%{"value" => "oi"}]},
        "member" => %{"user" => %{"username" => "maria"}}
      }

      assert {:ok, [%{text: "oi", name: "maria"}]} = Pepe.Webhooks.Discord.parse(payload)
    end

    test "parse falls back to the user field in a DM (no guild member)" do
      payload = %{
        "type" => 2,
        "token" => "tok",
        "id" => "i1",
        "data" => %{"name" => "ask", "options" => [%{"value" => "oi"}]},
        "user" => %{"username" => "maria"}
      }

      assert {:ok, [%{text: "oi", name: "maria"}]} = Pepe.Webhooks.Discord.parse(payload)
    end
  end

  describe "config + resolution" do
    test "put/get/delete a webhook connection" do
      Config.put_webhook("support", entry())
      assert Config.webhook_exists?("support")
      assert Config.get_webhook("support")["agent"] == "acme/support"

      Config.delete_webhook("support")
      refute Config.webhook_exists?("support")
    end

    test "resolve validates project + provider against the stored entry" do
      Config.put_webhook("support", entry())

      assert %{"slug" => "support"} = Webhooks.resolve("acme", "whatsapp", "support")
      # wrong project or provider in the path must not resolve
      assert Webhooks.resolve("globex", "whatsapp", "support") == nil
      assert Webhooks.resolve("acme", "stripe", "support") == nil
      assert Webhooks.resolve("acme", "whatsapp", "nope") == nil
    end

    test "root scope resolves via the 'root' path segment" do
      Config.put_webhook("geral", entry(%{"project" => nil}))
      assert %{"slug" => "geral"} = Webhooks.resolve("root", "whatsapp", "geral")
    end

    test "verify goes through the resolved connection" do
      Config.put_webhook("support", entry())

      assert {:ok, "99"} =
               Webhooks.verify("acme", "whatsapp", "support", %{
                 "hub.verify_token" => "vt",
                 "hub.challenge" => "99"
               })

      assert :error = Webhooks.verify("globex", "whatsapp", "support", %{})
    end

    test "handle_inbound rejects a bad signature" do
      Config.put_webhook("support", entry())

      assert {:error, :unauthorized} =
               Webhooks.handle_inbound("acme", "whatsapp", "support", "{}", %{}, %{
                 "x-hub-signature-256" => "sha256=bad"
               })
    end
  end

  describe "public_host/0 and callback_url/3" do
    setup do
      prev_public = System.get_env("PEPE_PUBLIC_URL")
      prev_phx = System.get_env("PHX_HOST")
      System.delete_env("PEPE_PUBLIC_URL")
      System.delete_env("PHX_HOST")

      on_exit(fn ->
        if prev_public, do: System.put_env("PEPE_PUBLIC_URL", prev_public), else: System.delete_env("PEPE_PUBLIC_URL")
        if prev_phx, do: System.put_env("PHX_HOST", prev_phx), else: System.delete_env("PHX_HOST")
      end)

      :ok
    end

    test "falls back to the YOUR_HOST placeholder when neither env var is set" do
      assert Webhooks.public_host() == "https://YOUR_HOST"
    end

    test "PHX_HOST fills in a real host once a server is actually configured to run" do
      System.put_env("PHX_HOST", "agents.example.com")
      assert Webhooks.public_host() == "https://agents.example.com"
    end

    test "PEPE_PUBLIC_URL overrides PHX_HOST outright" do
      System.put_env("PHX_HOST", "agents.example.com")
      System.put_env("PEPE_PUBLIC_URL", "https://custom.example.org:8443")
      assert Webhooks.public_host() == "https://custom.example.org:8443"
    end

    test "callback_url/3 defaults a nil project to the root segment" do
      System.put_env("PHX_HOST", "agents.example.com")
      assert Webhooks.callback_url(nil, "slack", "support") == "https://agents.example.com/webhooks/root/slack/support"
      assert Webhooks.callback_url("acme", "slack", "support") == "https://agents.example.com/webhooks/acme/slack/support"
    end
  end

  describe "per-connection gating (admin vs support)" do
    test "allowed_numbers gates who may message" do
      open = entry(%{"allowed_numbers" => []})
      assert Webhooks.allowed?(open, "5511000")

      gated = entry(%{"allowed_numbers" => ["5511999"]})
      assert Webhooks.allowed?(gated, "5511999")
      refute Webhooks.allowed?(gated, "5511000")
    end

    test "trainers decides whether the conversation learns" do
      refute Webhooks.learn?(entry(%{"trainers" => []}), "5511999")
      assert Webhooks.learn?(entry(%{"trainers" => ["*"]}), "5511999")
      assert Webhooks.learn?(entry(%{"trainers" => ["5511999"]}), "5511999")
      refute Webhooks.learn?(entry(%{"trainers" => ["5511000"]}), "5511999")
      # absent = default (learns) - but a support connection sets [] explicitly
      assert Webhooks.learn?(entry(), "5511999")
    end

    test "slash commands only fire for admin connections that enable them" do
      admin = entry(%{"mode" => "admin", "commands" => true})
      assert {:reset, _} = Webhooks.command(admin, "/new", "5511999")
      assert :chat = Webhooks.command(admin, "hello", "5511999")

      # support treats "/new" as plain text (no commands)
      assert :chat = Webhooks.command(entry(%{"mode" => "support"}), "/new", "5511999")
      # admin with commands disabled also passes it through
      assert :chat = Webhooks.command(entry(%{"mode" => "admin", "commands" => false}), "/new", "5511999")
    end
  end

  describe "/models and /model" do
    setup do
      Pepe.Config.put_model(%Pepe.Config.Model{name: "acme/model-a", base_url: "https://x", model: "gpt-a"})
      Pepe.Config.put_model(%Pepe.Config.Model{name: "globex/model-b", base_url: "https://x", model: "gpt-b"})
      Pepe.Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: "acme/model-a"})
      :ok
    end

    defp admin(overrides \\ %{}),
      do: entry(Map.merge(%{"mode" => "admin", "commands" => true, "trainers" => ["boss"]}, overrides))

    test "/models is scoped to the connection's project" do
      assert {:reply, text} = Webhooks.command(admin(), "/models", "boss")
      assert text =~ "model-a"
      refute text =~ "model-b"
    end

    test "/model with no args asks the session for its current model" do
      assert {:model_show} = Webhooks.command(admin(), "/model", "boss")
    end

    test "a trainer changing the model with no scope is asked to confirm" do
      assert {:model_set, "acme/model-a", nil, :global} = Webhooks.command(admin(), "/model acme/model-a", "boss")
    end

    test "a trainer stating a scope applies directly" do
      assert {:model_set, "acme/model-a", "session", :global} =
               Webhooks.command(admin(), "/model acme/model-a session", "boss")

      assert {:model_set, "acme/model-a", "global", :global} =
               Webhooks.command(admin(), "/model acme/model-a global", "boss")
    end

    test "a non-trainer gets :session permission - no asking, even with no scope stated" do
      assert {:model_set, "acme/model-a", nil, :session} =
               Webhooks.command(admin(), "/model acme/model-a", "5511999")
    end

    test "model_switch_locked drops non-trainers to :none" do
      locked = admin(%{"model_switch_locked" => true})
      assert {:model_set, "acme/model-a", nil, :none} = Webhooks.command(locked, "/model acme/model-a", "5511999")
      # a trainer is unaffected by the lock
      assert {:model_set, "acme/model-a", nil, :global} = Webhooks.command(locked, "/model acme/model-a", "boss")
    end

    test "support connections never get the model commands, locked or not" do
      support = entry(%{"mode" => "support"})
      assert :chat = Webhooks.command(support, "/models", "5511999")
      assert :chat = Webhooks.command(support, "/model acme/model-a", "5511999")
    end
  end

  describe "/agent" do
    setup do
      Pepe.Config.put_agent(%Pepe.Config.Agent{name: "acme/eng", model: nil})
      :ok
    end

    test "status/bind/unbind decisions, gated by whether the sender is a trainer" do
      a = admin()
      assert {:agent_status} = Webhooks.command(a, "/agent", "boss")
      assert {:agent_bind, "acme/eng", true} = Webhooks.command(a, "/agent acme/eng", "boss")
      assert {:agent_bind, nil, true} = Webhooks.command(a, "/agent none", "boss")
      # A non-trainer gets the same shape back - begin/3 is what actually refuses it (see
      # the full round-trip test below), same split /model uses between deciding and doing.
      assert {:agent_bind, "acme/eng", false} = Webhooks.command(a, "/agent acme/eng", "5511999")
    end

    test "binding a channel persists it, reasserts every turn, and survives /new - unlike switch_agent's own ephemeral routing" do
      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      slack_entry = admin(%{"provider" => "slack", "config" => %{"bot_token" => "xoxb-1"}})
      # `from` doubles as both the conversation id (session_key/2) and, absent a `sender_id`,
      # the actor learn?/2 checks - matching this suite's existing /model tests' convention.
      # "boss" is in admin/1's own `trainers: ["boss"]`.
      key = Webhooks.session_key(slack_entry, "boss")

      bind_message = %{from: "boss", text: "/agent acme/eng", id: "1.1"}
      assert :done = Webhooks.begin(%{entry: slack_entry, mod: Pepe.Webhooks.Slack, message: bind_message}, "/agent acme/eng", [])

      assert_receive {:delivered, _url, opts}, 1000
      assert opts[:json]["text"] =~ "acme/eng"
      assert Pepe.Config.channel_agent(key) == "acme/eng"
      assert %{agent: "acme/eng"} = Pepe.Agent.Session.status(key)

      # /new alone would revert to the connection's own default agent (see the locale test
      # above) - but the durable binding reasserts itself right back on the very next turn,
      # since apply_channel_binding/3 always wins over whatever a reset left behind.
      reset_message = %{from: "boss", text: "/new", id: "2.1"}
      assert :done = Webhooks.begin(%{entry: slack_entry, mod: Pepe.Webhooks.Slack, message: reset_message}, "/new", [])
      assert %{agent: "acme/eng"} = Pepe.Agent.Session.status(key)
    end

    test "agent_switch_locked refuses /agent NAME even for a trainer, but leaves status/none-arg alone" do
      locked = admin(%{"agent_switch_locked" => true})
      assert {:agent_status} = Webhooks.command(locked, "/agent", "boss")
      assert {:reply, text} = Webhooks.command(locked, "/agent acme/eng", "boss")
      assert text =~ "locked"
    end

    test "agent_switch_locked round-trip: the reply says so and nothing is written" do
      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      slack_entry = admin(%{"provider" => "slack", "config" => %{"bot_token" => "xoxb-1"}, "agent_switch_locked" => true})
      key = Webhooks.session_key(slack_entry, "boss")
      message = %{from: "boss", text: "/agent acme/eng", id: "1.1"}

      assert :done = Webhooks.begin(%{entry: slack_entry, mod: Pepe.Webhooks.Slack, message: message}, "/agent acme/eng", [])
      assert_receive {:delivered, _url, opts}, 1000
      assert opts[:json]["text"] =~ "locked"
      assert Pepe.Config.channel_agent(key) == nil
    end

    test "a non-trainer can't bind or unbind the channel, and nothing is written" do
      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      slack_entry = admin(%{"provider" => "slack", "config" => %{"bot_token" => "xoxb-1"}})
      key = Webhooks.session_key(slack_entry, "C1")
      # actor/1 (and so learn?/2) reads the message's `from` absent a `sender_id` override -
      # "C1" isn't in admin/1's own `trainers: ["boss"]`, so this is a non-trainer sender.
      message = %{from: "C1", text: "/agent acme/eng", id: "1.1"}

      assert :done = Webhooks.begin(%{entry: slack_entry, mod: Pepe.Webhooks.Slack, message: message}, "/agent acme/eng", [])
      assert_receive {:delivered, _url, opts}, 1000
      assert opts[:json]["text"] =~ "don't have permission"
      assert Pepe.Config.channel_agent(key) == nil
    end
  end

  describe "/mention" do
    test "on/off/status/invalid decisions" do
      a = admin()
      assert {:mention, true} = Webhooks.command(a, "/mention off", "boss")
      assert {:mention, false} = Webhooks.command(a, "/mention on", "boss")
      assert {:mention_status} = Webhooks.command(a, "/mention", "boss")
      assert {:reply, "Usage: /mention on|off"} = Webhooks.command(a, "/mention sideways", "boss")
    end

    test "only a trainer may change it; anyone may read it" do
      a = admin(%{"trainers" => ["U1"]})
      assert {:mention, true} = Webhooks.command(a, "/mention off", "U1")
      assert {:reply, denied} = Webhooks.command(a, "/mention off", "U2")
      assert denied =~ "don't have permission"
      assert {:reply, _} = Webhooks.command(a, "/mention on", "U2")
      assert {:mention_status} = Webhooks.command(a, "/mention", "U2")
    end

    test "command replies are built in Pepe's configured locale, not whatever locale happened to already be set on the lane's own process" do
      # begin/3 runs in the webhook lane's own GenServer process (see Pepe.Webhooks.Lane),
      # never the process that last called Config.put_locale/0 (Gettext's locale is
      # per-process) - a reply built here with the wrong locale renders in English even on
      # a Portuguese-configured install, which is exactly the bug this test guards against.
      prev_locale = Pepe.Config.locale()
      Pepe.Config.set_locale("pt_BR")
      on_exit(fn -> Pepe.Config.set_locale(prev_locale) end)

      Pepe.Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: nil})

      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      slack_entry = admin(%{"provider" => "slack", "config" => %{"bot_token" => "xoxb-1"}})
      message = %{from: "C1", text: "/new", id: "1.1"}

      assert :done = Webhooks.begin(%{entry: slack_entry, mod: Pepe.Webhooks.Slack, message: message}, "/new", [])

      assert_receive {:delivered, _url, opts}, 1_000
      assert opts[:json]["text"] == "🧹 Nova conversa."
    end

    test "invoked via an @mention, then waives mention for later plain messages" do
      {:ok, server} = Bandit.start_link(plug: {FixedReplyPlug, reply: "hello!"}, port: 0, scheme: :http)
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)

      Pepe.Config.put_model(%Pepe.Config.Model{name: "m", base_url: "http://localhost:#{port}", model: "gpt"})
      Pepe.Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: "m", tools: []})

      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      secret = "sign-me"

      slack_entry =
        admin(%{"provider" => "slack", "trainers" => ["*"], "config" => %{"bot_token" => "xoxb-1", "signing_secret" => secret}})

      Pepe.Config.put_webhook("acme-slack", slack_entry)

      # Every inbound is signed (the raw body is "{}" for all three calls here), so one valid,
      # fresh header set authenticates them all.
      ts = Integer.to_string(System.system_time(:second))
      sig = "v0=" <> (:crypto.mac(:hmac, :sha256, secret, "v0:#{ts}:{}") |> Base.encode16(case: :lower))
      headers = %{"x-slack-request-timestamp" => ts, "x-slack-signature" => sig}

      channel_message = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "text" => "just chatting, not mentioning anyone", "channel" => "C1", "ts" => "1.0"}
      }

      # Without the waiver: a plain channel message (no app_mention, not a DM) never
      # reaches the agent.
      assert :ok = Webhooks.handle_inbound("acme", "slack", "acme-slack", "{}", channel_message, headers)
      refute_receive {:delivered, _url, _opts}, 200

      # A real command reaches the agent regardless of the mention gate (see
      # real_command?/2) - this exercises the app_mention route anyway, since Slack's own
      # client refuses to send a bare "/mention off" as a message at all without either a
      # leading space or an @mention in front (see the "reaches the agent with no @mention
      # at all" test below for the no-mention path itself). Unlike plain "message" text, the
      # mention prefix must still be stripped for this to parse as "/mention off" rather than
      # chat text (see Slack.parse/1).
      mention_off = %{
        "type" => "event_callback",
        "event" => %{"type" => "app_mention", "text" => "<@U0BOT123> /mention off", "channel" => "C1", "ts" => "2.0"}
      }

      assert :ok = Webhooks.handle_inbound("acme", "slack", "acme-slack", "{}", mention_off, headers)
      assert_receive {:delivered, "https://slack.com/api/chat.postMessage", opts}, 1000
      assert opts[:json]["text"] =~ "without being @mentioned"

      # With the waiver now set for channel C1, the earlier plain (unaddressed)
      # message shape reaches the agent and gets a real reply delivered back.
      assert :ok = Webhooks.handle_inbound("acme", "slack", "acme-slack", "{}", channel_message, headers)
      assert_receive {:delivered, "https://slack.com/api/chat.postMessage", opts2}, 1000
      assert opts2[:json]["text"] == "hello!"
    end

    test "a real command reaches the agent with no @mention at all, in a channel that still requires one for plain chat" do
      parent = self()

      Mimic.stub(Req, :post, fn "https://slack.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end)

      secret = "sign-me"
      # require_mention left at its default (on) - a command still has to get through with
      # no @mention and no prior waiver, which is the whole point of this test.
      slack_entry =
        admin(%{"provider" => "slack", "trainers" => ["*"], "config" => %{"bot_token" => "xoxb-1", "signing_secret" => secret}})

      Pepe.Config.put_webhook("acme-slack", slack_entry)

      ts = Integer.to_string(System.system_time(:second))
      sig = "v0=" <> (:crypto.mac(:hmac, :sha256, secret, "v0:#{ts}:{}") |> Base.encode16(case: :lower))
      headers = %{"x-slack-request-timestamp" => ts, "x-slack-signature" => sig}

      # No app_mention wrapper, no leading @mention text - just the bare command, the shape a
      # human gets after typing a leading space to dodge Slack's own slash-command interception
      # (see the "Typing a command in Slack" note in the webhooks docs).
      bare_command = %{
        "type" => "event_callback",
        "event" => %{"type" => "message", "text" => "/mention off", "channel" => "C1", "ts" => "3.0"}
      }

      assert :ok = Webhooks.handle_inbound("acme", "slack", "acme-slack", "{}", bare_command, headers)
      assert_receive {:delivered, "https://slack.com/api/chat.postMessage", opts}, 1000
      assert opts[:json]["text"] =~ "without being @mentioned"
    end
  end

  describe "untrusted content taint" do
    # A model that asks for a risky bash call on the first turn, then reports back whatever
    # the tool result said once it comes back - so the test can see, in the delivered reply,
    # whether the call actually ran or was refused.
    defmodule RiskyToolPlug do
      @moduledoc false
      import Plug.Conn

      def init(opts), do: opts

      def call(conn, _opts) do
        {:ok, body, conn} = read_body(conn)
        msgs = body |> Jason.decode!() |> Map.fetch!("messages")
        tool = Enum.find(msgs, &(&1["role"] == "tool"))

        message =
          if tool do
            %{"role" => "assistant", "content" => "tool said: #{tool["content"]}"}
          else
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => "rm -rf /tmp/whatsapp_test_dummy"})}
                }
              ]
            }
          end

        payload = %{"choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}]}
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
      end
    end

    test "an inbound webhook message withdraws auto_approve, the same way an attached Telegram document already does" do
      {:ok, server} = Bandit.start_link(plug: RiskyToolPlug, port: 0, scheme: :http)
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)

      Config.put_model(%Pepe.Config.Model{name: "m", base_url: "http://localhost:#{port}", model: "gpt"})

      # Pre-approved for everything, the way a real support agent is set up so it doesn't ask
      # about every read - which is exactly the setup an anonymous webhook sender must not be
      # able to exploit for a risky call with nobody watching.
      Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: "m", tools: ["bash"], auto_approve: ["*"]})

      parent = self()

      Mimic.stub(Req, :post, fn "https://graph.facebook.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"messages" => [%{"id" => "wamid.out"}]}}}
      end)

      e = entry()
      Config.put_webhook("support", e)

      body =
        Jason.encode!(%{
          "entry" => [
            %{
              "changes" => [
                %{
                  "value" => %{
                    "messages" => [
                      %{"from" => "5511999", "type" => "text", "text" => %{"body" => "clean up the temp dir"}, "id" => "wamid.in"}
                    ]
                  }
                }
              ]
            }
          ]
        })

      sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, "s3cr3t", body) |> Base.encode16(case: :lower))

      assert :ok =
               Webhooks.handle_inbound("acme", "whatsapp", "support", body, Jason.decode!(body), %{
                 "x-hub-signature-256" => sig
               })

      assert_receive {:delivered, _url, opts}, 1000
      # Nobody was there to ask (webhooks pass `authorize: nil`) and the message is now
      # tainted, so the pre-approved `bash` call was refused rather than silently run - see
      # Pepe.Permissions' unattended_reason/1 for this exact wording.
      assert opts[:json]["text"]["body"] =~ "content from outside"
      refute opts[:json]["text"]["body"] =~ "/tmp/whatsapp_test_dummy"
    end
  end

  describe "message limit checked before spending on media" do
    test "a project already over its message limit never pays for a download/transcription" do
      Config.put_model(%Pepe.Config.Model{name: "m", base_url: "http://localhost:1", model: "gpt"})
      Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: "m", tools: []})

      parent = self()

      Mimic.stub(Pepe.Usage, :over_message_limit?, fn "acme" ->
        send(parent, :checked_message_limit)
        true
      end)

      Mimic.reject(&Pepe.Webhooks.Media.resolve/3)

      e = entry()
      Config.put_webhook("support", e)

      body =
        Jason.encode!(%{
          "entry" => [
            %{
              "changes" => [
                %{
                  "value" => %{
                    "messages" => [
                      %{
                        "from" => "5511999",
                        "type" => "audio",
                        "audio" => %{"id" => "media123", "mime_type" => "audio/ogg"},
                        "id" => "wamid.in"
                      }
                    ]
                  }
                }
              ]
            }
          ]
        })

      sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, "s3cr3t", body) |> Base.encode16(case: :lower))

      assert :ok =
               Webhooks.handle_inbound("acme", "whatsapp", "support", body, Jason.decode!(body), %{
                 "x-hub-signature-256" => sig
               })

      # Proves the dispatch task actually reached the limit check (not just that nothing
      # crashed) before the test process exits - a real signal instead of a timed guess.
      assert_receive :checked_message_limit, 1000
    end
  end

  describe "a lane that refuses a message" do
    test "the sender is told, not left silent" do
      Config.put_model(%Pepe.Config.Model{name: "m", base_url: "http://localhost:1", model: "gpt"})
      Config.put_agent(%Pepe.Config.Agent{name: "acme/support", model: "m", tools: []})

      parent = self()

      Mimic.stub(Pepe.Webhooks.Lane, :submit, fn _key, _job -> {:error, :full} end)

      Mimic.stub(Req, :post, fn "https://graph.facebook.com" <> _ = url, opts ->
        send(parent, {:delivered, url, opts})
        {:ok, %{status: 200, body: %{"messages" => [%{"id" => "wamid.out"}]}}}
      end)

      e = entry()
      Config.put_webhook("support", e)

      body =
        Jason.encode!(%{
          "entry" => [
            %{
              "changes" => [
                %{"value" => %{"messages" => [%{"from" => "5511999", "type" => "text", "text" => %{"body" => "hi"}, "id" => "wamid.in"}]}}
              ]
            }
          ]
        })

      sig = "sha256=" <> (:crypto.mac(:hmac, :sha256, "s3cr3t", body) |> Base.encode16(case: :lower))

      assert :ok =
               Webhooks.handle_inbound("acme", "whatsapp", "support", body, Jason.decode!(body), %{
                 "x-hub-signature-256" => sig
               })

      assert_receive {:delivered, _url, opts}, 1000
      assert opts[:json]["text"]["body"] =~ "behind"
    end
  end
end
