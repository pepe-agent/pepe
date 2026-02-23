defmodule Pepe.WebhooksTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Webhooks
  alias Pepe.Webhooks.WhatsApp

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_wh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "provider" => "whatsapp",
        "company" => "acme",
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

    test "parse extracts text messages and ignores the rest" do
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
                    %{"from" => "5511999", "type" => "image", "image" => %{"id" => "x"}}
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, [%{from: "5511999", text: "oi", id: "m1"}]} = WhatsApp.parse(payload)

      assert :ignore =
               WhatsApp.parse(%{"entry" => [%{"changes" => [%{"value" => %{"statuses" => []}}]}]})
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

    test "resolve validates company + provider against the stored entry" do
      Config.put_webhook("support", entry())

      assert %{"slug" => "support"} = Webhooks.resolve("acme", "whatsapp", "support")
      # wrong company or provider in the path must not resolve
      assert Webhooks.resolve("globex", "whatsapp", "support") == nil
      assert Webhooks.resolve("acme", "stripe", "support") == nil
      assert Webhooks.resolve("acme", "whatsapp", "nope") == nil
    end

    test "root scope resolves via the 'root' path segment" do
      Config.put_webhook("geral", entry(%{"company" => nil}))
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
      assert {:reset, _} = Webhooks.command(admin, "/new")
      assert :chat = Webhooks.command(admin, "hello")

      # support treats "/new" as plain text (no commands)
      assert :chat = Webhooks.command(entry(%{"mode" => "support"}), "/new")
      # admin with commands disabled also passes it through
      assert :chat = Webhooks.command(entry(%{"mode" => "admin", "commands" => false}), "/new")
    end
  end
end
