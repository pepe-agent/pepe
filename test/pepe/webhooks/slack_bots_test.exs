defmodule Pepe.Webhooks.SlackBotsTest do
  @moduledoc """
  A channel that gets its work from another system (a help desk posting each new ticket): the
  message is written by an app, and its content sits in the coloured-bar attachment rather than
  in `text`. Both used to make it vanish. What must hold: an attachment is read, an app's message
  is dropped unless the connection names that app, and this app's own messages are never let in,
  whatever the list says.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Webhooks
  alias Pepe.Webhooks.Slack

  @moduletag :capture_log

  defp event(overrides) do
    %{
      "type" => "event_callback",
      "api_app_id" => "AME",
      "authorizations" => [%{"user_id" => "UME"}],
      "event" =>
        Map.merge(
          %{
            "type" => "message",
            "channel" => "C1",
            "channel_type" => "im",
            "ts" => "1.#{System.unique_integer([:positive])}",
            "text" => "",
            "subtype" => "bot_message",
            "bot_id" => "BZOHO",
            "app_id" => "AZOHO",
            "username" => "Caren",
            "attachments" => [
              %{
                "pretext" => "New ticket received in Caren.app#247",
                "title" => "Habilitar a opção de desatribuir",
                "text" => "Boa tarde, seria possivel liberar?",
                "fields" => [
                  %{"title" => "Customer Email", "value" => "ana@example.com"},
                  %{"title" => "Priority", "value" => "-"}
                ]
              }
            ]
          },
          overrides
        )
    }
  end

  describe "parse/1" do
    test "an attachment's title, body and fields are the message when text is empty" do
      assert {:ok, [msg]} = Slack.parse(event(%{}))
      assert msg.text =~ "New ticket received in Caren.app#247"
      assert msg.text =~ "Habilitar a opção de desatribuir"
      assert msg.text =~ "Customer Email: ana@example.com"
    end

    test "a message from an app is marked with the ids it carries" do
      assert {:ok, [%{bot: %{id: "BZOHO", app: "AZOHO", name: "Caren"}}]} = Slack.parse(event(%{}))
    end

    test "a message from a person carries no bot mark, and its text is unchanged" do
      payload = event(%{"subtype" => nil, "bot_id" => nil, "app_id" => nil, "text" => "oi", "attachments" => nil})
      assert {:ok, [msg]} = Slack.parse(payload)
      assert msg.text == "oi"
      refute Map.has_key?(msg, :bot)
    end

    test "this app's own messages never get through" do
      assert :ignore = Slack.parse(event(%{"app_id" => "AME"}))
      assert :ignore = Slack.parse(event(%{"user" => "UME"}))
    end

    test "an edit or other subtype is still ignored" do
      assert :ignore = Slack.parse(event(%{"subtype" => "message_changed"}))
    end
  end

  describe "the connection decides which apps are answered" do
    setup do
      {:ok, _} = Application.ensure_all_started(:pepe)
      home = Path.join(System.tmp_dir!(), "pepe_slack_bots_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(home)
      end)

      parent = self()
      stub(Pepe.Webhooks.Lane, :submit, fn _key, job -> send(parent, {:submitted, job.message}) && :ok end)
      :ok
    end

    defp connect(config) do
      Config.put_webhook("desk", %{"provider" => "slack", "agent" => "support", "config" => Map.merge(%{"bot_token" => "x"}, config)})
    end

    test "dropped by default" do
      connect(%{})
      assert :ok = Webhooks.handle_gateway_event("desk", event(%{}))
      refute_receive {:submitted, _}, 300
    end

    test "answered once its bot id is listed" do
      connect(%{"accept_bots" => "BZOHO"})
      assert :ok = Webhooks.handle_gateway_event("desk", event(%{}))
      assert_receive {:submitted, %{text: text}}, 1_000
      assert text =~ "New ticket received"
    end

    test "its app id works too, in a comma separated list" do
      connect(%{"accept_bots" => "BOTHER, AZOHO"})
      assert :ok = Webhooks.handle_gateway_event("desk", event(%{}))
      assert_receive {:submitted, _}, 1_000
    end

    test "another app is still dropped" do
      connect(%{"accept_bots" => "BOTHER"})
      assert :ok = Webhooks.handle_gateway_event("desk", event(%{}))
      refute_receive {:submitted, _}, 300
    end

    test "the bot's own message is never answered, even if its own id is listed" do
      connect(%{"accept_bots" => "AME, BZOHO"})
      assert :ok = Webhooks.handle_gateway_event("desk", event(%{"app_id" => "AME", "bot_id" => "BME"}))
      refute_receive {:submitted, _}, 300
    end
  end
end
