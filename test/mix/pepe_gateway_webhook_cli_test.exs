defmodule Mix.Tasks.PepeGatewayWebhookCliTest do
  @moduledoc """
  `mix pepe gateway discord` and the attachment limit of `mix pepe gateway whatsapp`: the CLI
  half of options that also live in the dashboard and in `pepe setup`. Pins what is stored (the
  values the provider actually reads, as strings, like the dashboard writes them), that a
  connection with nothing to receive on is refused before it is written, and that the other
  provider's connections are never touched by a Discord command.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_gw_webhook_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  describe "discord add" do
    test "a connection that reads channel messages stores what the gateway reads" do
      pepe([
        "gateway",
        "discord",
        "add",
        "chat",
        "--agent",
        "acme/support",
        "--gateway",
        "--bot-token",
        "${DISCORD_TOKEN}",
        "--no-require-mention",
        "--max-attachment-mb",
        "8"
      ])

      entry = Config.get_webhook("chat")
      assert entry["provider"] == "discord"
      assert entry["agent"] == "acme/support"
      assert entry["mode"] == "support"

      assert entry["config"] == %{
               "bot_token" => "${DISCORD_TOKEN}",
               "receive_channel_messages" => "true",
               "require_mention" => "false",
               "max_attachment_mb" => "8"
             }

      # Active once the environment variable the token refers to is there to read.
      refute Pepe.Gateways.Discord.active?(entry)
      System.put_env("DISCORD_TOKEN", "the-token")
      on_exit(fn -> System.delete_env("DISCORD_TOKEN") end)
      assert Pepe.Gateways.Discord.active?(entry)
    end

    test "a slash-command connection needs no bot token and prints its endpoint" do
      out = pepe(["gateway", "discord", "add", "cmds", "--agent", "a", "--application-id", "123", "--public-key", "abcd"])

      assert out =~ "/webhooks/default/discord/cmds"
      entry = Config.get_webhook("cmds")
      assert entry["config"] == %{"application_id" => "123", "public_key" => "abcd"}
      refute Pepe.Gateways.Discord.active?(entry)
    end

    test "the mention requirement is left at its default unless turned off" do
      pepe(["gateway", "discord", "add", "chat", "--agent", "a", "--gateway", "--bot-token", "t"])
      refute Map.has_key?(Config.get_webhook("chat")["config"], "require_mention")
    end

    test "--gateway without a token is refused, and nothing is written" do
      err = pepe_err(["gateway", "discord", "add", "chat", "--agent", "a", "--gateway"])

      assert err =~ "--bot-token"
      assert Config.get_webhook("chat") == nil
    end

    test "a connection with neither slash commands nor the gateway would receive nothing, so it is refused" do
      err = pepe_err(["gateway", "discord", "add", "chat", "--agent", "a"])

      assert err =~ "--application-id"
      assert Config.get_webhook("chat") == nil
    end

    test "an agent is required" do
      assert pepe_err(["gateway", "discord", "add", "chat", "--gateway", "--bot-token", "t"]) =~ "--agent"
    end

    test "a name already taken is refused" do
      pepe(["gateway", "discord", "add", "chat", "--agent", "a", "--gateway", "--bot-token", "t"])
      assert pepe_err(["gateway", "discord", "add", "chat", "--agent", "b", "--gateway", "--bot-token", "t"]) =~ "already exists"
      assert Config.get_webhook("chat")["agent"] == "a"
    end
  end

  describe "discord list, set-agent, remove" do
    setup do
      pepe(["gateway", "discord", "add", "chat", "--agent", "a", "--gateway", "--bot-token", "t"])
      pepe(["gateway", "whatsapp", "add", "wa", "--agent", "a", "--phone-number-id", "1"])
      :ok
    end

    test "list shows Discord connections and how they receive, and only those" do
      out = pepe(["gateway", "discord", "list"])

      assert out =~ "chat"
      assert out =~ "channel messages on"
      refute out =~ "wa"
    end

    test "set-agent rebinds it" do
      pepe(["gateway", "discord", "set-agent", "chat", "b"])
      assert Config.get_webhook("chat")["agent"] == "b"
    end

    test "it will not rebind or remove another provider's connection" do
      assert pepe_err(["gateway", "discord", "set-agent", "wa", "b"]) =~ "unknown discord connection"
      assert pepe_err(["gateway", "discord", "remove", "wa"]) =~ "unknown discord connection"
      assert Config.get_webhook("wa")["agent"] == "a"
    end

    test "remove deletes it" do
      pepe(["gateway", "discord", "remove", "chat"])
      assert Config.get_webhook("chat") == nil
    end
  end

  describe "whatsapp add --max-attachment-mb" do
    test "is stored the way the dashboard stores it" do
      pepe(["gateway", "whatsapp", "add", "wa", "--agent", "a", "--phone-number-id", "1", "--max-attachment-mb", "12"])
      assert Config.get_webhook("wa")["config"]["max_attachment_mb"] == "12"
    end

    test "is left out when not given, so the default applies" do
      pepe(["gateway", "whatsapp", "add", "wa", "--agent", "a", "--phone-number-id", "1"])
      refute Map.has_key?(Config.get_webhook("wa")["config"], "max_attachment_mb")
    end
  end
end
