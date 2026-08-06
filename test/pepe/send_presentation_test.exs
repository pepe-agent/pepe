defmodule Pepe.SendPresentationTest do
  @moduledoc """
  `send_presentation` routes to the session's channel exactly like `send_file` does.
  Slack renders real Block Kit (`Pepe.Webhooks.Slack.deliver_blocks/3`); a provider with
  no `deliver_blocks/3` (WhatsApp) still gets the content, flattened to plain text by
  `Pepe.Webhooks.deliver_blocks/4`'s own fallback.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Config
  alias Pepe.Tools.SendPresentation
  alias Pepe.Webhooks.Slack

  @blocks [
    %{"type" => "text", "text" => "Here are your results:"},
    %{"type" => "table", "headers" => ["name", "score"], "rows" => [["zak", "9"]]},
    %{"type" => "buttons", "buttons" => [%{"label" => "Approve", "value" => "yes"}, %{"label" => "Reject", "value" => "no"}]}
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_sendpres_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # ---- Slack renders real Block Kit ---------------------------------------------------

  test "slack's deliver_blocks/3 sends real Block Kit, not flattened text" do
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    assert :ok = Slack.deliver_blocks(%{"config" => %{"bot_token" => "xoxb-1"}}, "C1", @blocks)
    assert_received {:req, "https://slack.com/api/chat.postMessage", opts}

    body = opts[:json]
    assert is_binary(body["text"]) and body["text"] =~ "results"

    kit = body["blocks"]
    assert [%{"type" => "section"}, %{"type" => "section"}, %{"type" => "actions"} = actions] = kit
    assert [%{"type" => "button", "value" => "yes"}, %{"type" => "button", "value" => "no"}] = actions["elements"]
  end

  # ---- the send_presentation tool routes to the session's channel --------------------

  test "routes a Telegram session to plain flattened text (no deliver_blocks concept there)" do
    Config.put_telegram(%{"bot_token" => "T", "allowed_chats" => []})
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    ctx = %{session_key: "telegram:842064390"}
    assert {:ok, _} = SendPresentation.run(%{"blocks" => @blocks}, ctx)
    assert_received {:req, url, opts}
    assert url =~ "/sendMessage"
    assert opts[:json][:text] =~ "results"
    assert opts[:json][:text] =~ "[Approve]"
  end

  test "routes a Slack session to the bound connection, with real Block Kit" do
    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})
    Config.put_webhook("team", %{"provider" => "slack", "agent" => "assistant", "config" => %{"bot_token" => "xoxb-9"}})
    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200, body: %{"ok" => true}}}
    end)

    ctx = %{session_key: "slack:assistant:C42"}
    assert {:ok, _} = SendPresentation.run(%{"blocks" => @blocks}, ctx)
    assert_received {:req, "https://slack.com/api/chat.postMessage", opts}
    assert opts[:json]["channel"] == "C42"
    assert is_list(opts[:json]["blocks"])
  end

  test "a provider with no deliver_blocks/3 (WhatsApp) still delivers, flattened to text" do
    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})

    Config.put_webhook("wa", %{
      "provider" => "whatsapp",
      "agent" => "assistant",
      "config" => %{"phone_number_id" => "999", "access_token" => "tok"}
    })

    parent = self()

    Mimic.stub(Req, :post, fn url, opts ->
      send(parent, {:req, url, opts})
      {:ok, %{status: 200}}
    end)

    ctx = %{session_key: "whatsapp:assistant:5511"}
    assert {:ok, _} = SendPresentation.run(%{"blocks" => @blocks}, ctx)
    assert_received {:req, url, opts}
    assert url =~ "/messages"
    assert opts[:json]["text"]["body"] =~ "[Approve]"
  end

  test "malformed blocks are refused with a clear error, not sent" do
    Mimic.reject(Req, :post, 2)
    ctx = %{session_key: "telegram:1"}
    assert {:error, msg} = SendPresentation.run(%{"blocks" => [%{"type" => "text"}]}, ctx)
    assert msg =~ "malformed"
  end

  test "no channel to send to reports a clear error" do
    assert {:error, msg} = SendPresentation.run(%{"blocks" => [%{"type" => "text", "text" => "hi"}]}, %{})
    assert msg =~ "no conversation channel"
  end
end
