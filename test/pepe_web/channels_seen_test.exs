defmodule PepeWeb.ChannelsSeenTest do
  @moduledoc """
  The Channels page lists, under each connection and each Telegram bot, the channels it has
  heard from. Every setting on a row has two levels: the connection's default and the
  channel's own value, which wins; the row says which one applies and can drop the channel's
  own so the connection's applies again.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.SeenChannels

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_seen_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "assistant"})
    Config.put_agent(%Agent{name: "sales"})
    Config.set_default_agent("assistant")

    Config.put_webhook("desk", %{
      "provider" => "slack",
      "agent" => "default/assistant",
      "mode" => "admin",
      "trainers" => ["U1"],
      "config" => %{"bot_token" => "${DESK_TOKEN}", "signing_secret" => "${DESK_SECRET}"}
    })

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  @t0 1_700_000_000

  defp open_desk(view), do: view |> element("#seen-desk button[phx-click=toggle]") |> render_click()

  # The tag on one setting's row: "own" or "from the connection".
  defp origin(html, form_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{form_id} span")
    |> LazyHTML.text()
  end

  test "a connection with no channel yet says so" do
    {:ok, _view, html} = live(conn(), "/bots")
    assert html =~ "No channels heard from yet."
  end

  test "the count opens into the list, with the name, the id, the kind and the last activity" do
    SeenChannels.touch("desk", "slack", "C1", kind: "group", name: "#ops", now: @t0 + 10)
    SeenChannels.touch("desk", "slack", "D9", kind: "dm", now: @t0)

    {:ok, view, html} = live(conn(), "/bots")
    assert html =~ "2 channels"
    refute html =~ "#ops"

    html = open_desk(view)
    assert html =~ "#ops"
    assert html =~ "C1"
    assert html =~ "D9"
    assert html =~ "group"
    assert html =~ "direct message"
    assert html =~ "days ago"
  end

  describe "agent" do
    test "the channel's own binding wins over the connection's, is tagged as such, and the reset goes back" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
      key = "slack:default/assistant:C1"

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_desk(view)
      assert origin(html, "seen-desk-agent-0") =~ "from the connection"
      assert html =~ "The connection&#39;s: default/assistant"

      html = view |> element("#seen-desk-agent-0") |> render_change(%{"channel" => "C1", "agent" => "default/sales"})
      assert Config.channel_agent(key) == "default/sales"
      assert origin(html, "seen-desk-agent-0") =~ "own"

      # An agent the picker never offered is refused.
      view |> element("#seen-desk-agent-0") |> render_change(%{"channel" => "C1", "agent" => "other/agent"})
      assert Config.channel_agent(key) == "default/sales"

      html = view |> element("#seen-desk button[phx-click=reset_agent][phx-value-channel=C1]") |> render_click()
      assert Config.channel_agent(key) == nil
      assert origin(html, "seen-desk-agent-0") =~ "from the connection"
    end

    test "a conversation already open in the channel follows the binding, and goes back to the connection's agent when it is dropped" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
      key = "slack:default/assistant:C1"
      SessionSupervisor.ensure(key, "default/assistant")

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)

      view |> element("#seen-desk-agent-0") |> render_change(%{"channel" => "C1", "agent" => "default/sales"})
      assert %{agent: "default/sales"} = Session.status(key)

      view |> element("#seen-desk button[phx-click=reset_agent][phx-value-channel=C1]") |> render_click()
      assert %{agent: "default/assistant"} = Session.status(key)
    end
  end

  describe "mention" do
    test "inherits the connection's default until the channel has its own, in either direction, and can go back" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_desk(view)
      assert origin(html, "seen-desk-mention-0") =~ "from the connection"
      assert html =~ "Use the connection&#39;s: requires a mention"
      assert Config.channel_mention("desk:C1") == nil

      html = view |> element("#seen-desk-mention-0") |> render_change(%{"channel" => "C1", "mention" => "optional"})
      assert Config.channel_mention("desk:C1") == true
      assert origin(html, "seen-desk-mention-0") =~ "own"

      view |> element("#seen-desk-mention-0") |> render_change(%{"channel" => "C1", "mention" => "required"})
      assert Config.channel_mention("desk:C1") == false

      html = view |> element("#seen-desk button[phx-click=reset_mention][phx-value-channel=C1]") |> render_click()
      assert Config.channel_mention("desk:C1") == nil
      assert origin(html, "seen-desk-mention-0") =~ "from the connection"
    end

    test "a direct message is a channel too and carries its own value" do
      SeenChannels.touch("desk", "slack", "D9", kind: "dm", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)

      view |> element("#seen-desk-mention-0") |> render_change(%{"channel" => "D9", "mention" => "required"})
      assert Config.channel_mention("desk:D9") == false
    end

    test "the connection's default shows on the card and in the inherit choice" do
      Config.put_webhook("desk", Map.put(Config.get_webhook("desk"), "mention_optional", true))
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

      {:ok, view, html} = live(conn(), "/bots")
      assert html =~ "Yes, in every channel"

      html = open_desk(view)
      assert html =~ "Use the connection&#39;s: answers without a mention"
    end

    test "a provider that answers everything (WhatsApp) gets no mention row" do
      Config.put_webhook("wa", %{
        "provider" => "whatsapp",
        "agent" => "default/assistant",
        "mode" => "support",
        "config" => %{"phone_number_id" => "1", "access_token" => "${WA}", "app_secret" => "${WAS}", "verify_token" => "v"}
      })

      SeenChannels.touch("wa", "whatsapp", "5511999", kind: "dm", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      view |> element("#seen-wa button[phx-click=toggle]") |> render_click()
      refute has_element?(view, "#seen-wa-mention-0")
      assert has_element?(view, "#seen-wa-agent-0")
    end
  end

  describe "who can train" do
    test "is the connection's until the channel gets its own list, and can go back" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_desk(view)
      assert origin(html, "seen-desk-trainers-0") =~ "from the connection"
      assert html =~ "The connection&#39;s: U1"

      html = view |> form("#seen-desk-trainers-0", %{"trainers" => "<@U2>, U3"}) |> render_submit()
      assert Config.channel_trainers("desk:C1") == ["U2", "U3"]
      assert origin(html, "seen-desk-trainers-0") =~ "own"

      html = view |> element("#seen-desk button[phx-click=reset_trainers][phx-value-channel=C1]") |> render_click()
      assert Config.channel_trainers("desk:C1") == nil
      assert origin(html, "seen-desk-trainers-0") =~ "from the connection"
    end

    test "a channel with a value of its own that never sent a message is still listed" do
      Config.put_channel_trainers("desk:C7", ["*"])
      Config.put_channel_mention("desk:C8", true)

      {:ok, view, html} = live(conn(), "/bots")
      assert html =~ "2 channels"

      html = open_desk(view)
      assert html =~ "C7"
      assert html =~ "C8"
      assert html =~ "no message yet"
      assert origin(html, "seen-desk-trainers-0") =~ "own"
      assert origin(html, "seen-desk-mention-1") =~ "own"
    end
  end

  test "a Telegram bot lists its groups and chats, with the agent picker only" do
    SeenChannels.touch("default", "telegram", "-1001", kind: "group", name: "Ops team", now: @t0)

    {:ok, view, html} = live(conn(), "/bots")
    assert html =~ "1 channel"

    html = view |> element("#seen-telegram-default button[phx-click=toggle]") |> render_click()
    assert html =~ "Ops team"
    assert html =~ "The bot&#39;s: the default agent"
    assert html =~ "from the bot"
    refute has_element?(view, "#seen-telegram-default-mention-0")
    refute has_element?(view, "#seen-telegram-default-trainers-0")

    html = view |> element("#seen-telegram-default-agent-0") |> render_change(%{"channel" => "-1001", "agent" => "default/sales"})
    assert Config.channel_agent("telegram:-1001") == "default/sales"
    assert html =~ "Use the bot&#39;s"
  end

  test "the connection form offers the mention default only where mentions are gated, and saves it" do
    {:ok, view, _html} = live(conn(), "/bots")

    view |> element("button[phx-value-name='slack']") |> render_click()
    assert render(view) =~ "Answer without being mentioned"

    view
    |> form("form[phx-submit=save]", %{
      "slug" => "ops",
      "agent" => "default/assistant",
      "mode" => "admin",
      "project" => "default",
      "mention_optional" => "true",
      "cfg" => %{"bot_token" => "${T}", "signing_secret" => "${S}"}
    })
    |> render_submit()

    assert Config.get_webhook("ops")["mention_optional"] == true

    view |> element("button[phx-value-name='whatsapp']") |> render_click()
    refute render(view) =~ "Answer without being mentioned"
  end

  test "removing a connection forgets its channels" do
    SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

    {:ok, view, _html} = live(conn(), "/bots")
    view |> element("button[phx-click=delete][phx-value-slug=desk]") |> render_click()

    assert SeenChannels.list("desk") == []
  end
end
