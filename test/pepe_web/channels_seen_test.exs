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
  alias Pepe.SeenPeople

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

    test "a direct message always answers, so it has no mention row, but keeps its agent and trainers" do
      SeenChannels.touch("desk", "slack", "D9", kind: "dm", now: @t0 + 10)
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)

      # Row 0 is the DM (most recent), row 1 the group.
      refute has_element?(view, "#seen-desk-mention-0")
      assert has_element?(view, "#seen-desk-agent-0")
      assert has_element?(view, "#seen-desk-trainers-0")
      assert has_element?(view, "#seen-desk-mention-1")
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
    test "is the connection's until the channel gets its own list, picked from the people heard there, and can go back" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
      SeenChannels.touch("desk", "slack", "C2", kind: "group", now: @t0)
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)
      SeenPeople.touch("desk", "C2", "U3", name: "Bruno", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_desk(view)
      assert origin(html, "seen-desk-trainers-0") =~ "from the connection"
      assert html =~ "The connection&#39;s: U1"

      # The people only show once "only these people" is picked, and only those heard in C1.
      refute has_element?(view, "#seen-desk-trainers-0 input[value=U2]")
      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "list"}}) |> render_change()
      assert has_element?(view, "#seen-desk-trainers-0 input[value=U2]")
      assert render(view) =~ "Ana"
      refute has_element?(view, "#seen-desk-trainers-0 input[value=U3]")
      # Nothing is stored until Save.
      assert Config.channel_trainers("desk:C1") == nil

      html =
        view
        |> form("#seen-desk-trainers-0", %{"trainers" => %{"people" => ["U2"], "extra" => "<@U7>"}})
        |> render_submit()

      assert Config.channel_trainers("desk:C1") == ["U2", "U7"]
      assert origin(html, "seen-desk-trainers-0") =~ "own"
      # The id added by hand, never heard from, stays listed and checked.
      assert has_element?(view, "#seen-desk-trainers-0 input[value=U7][checked]")

      html = view |> element("#seen-desk button[phx-click=reset_trainers][phx-value-channel=C1]") |> render_click()
      assert Config.channel_trainers("desk:C1") == nil
      assert origin(html, "seen-desk-trainers-0") =~ "from the connection"
    end

    test "a stored id nobody has heard from shows as its id and stays checked" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
      Config.put_channel_trainers("desk:C1", ["U9"])

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)

      assert has_element?(view, "#seen-desk-trainers-0 input[value=U9][checked]")
    end

    test "everyone, no one and the connection's are picked as a mode" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)

      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "*"}}) |> render_submit()
      assert Config.channel_trainers("desk:C1") == ["*"]

      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "none"}}) |> render_submit()
      assert Config.channel_trainers("desk:C1") == []

      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "default"}}) |> render_submit()
      assert Config.channel_trainers("desk:C1") == nil
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

  describe "the connection form's trainers" do
    defp open_edit(view) do
      view |> element("button[phx-click=edit][phx-value-slug=desk]") |> render_click()
      render(view)
    end

    test "offers the people heard on any channel, annotated with where, and saves the ones checked plus a typed id" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", name: "#ops", now: @t0)
      SeenChannels.touch("desk", "slack", "D9", kind: "dm", now: @t0)
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)
      SeenPeople.touch("desk", "D9", "U2", now: @t0)
      SeenPeople.touch("desk", "D9", "U3", name: "Bruno", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_edit(view)

      # The stored list is ["U1"], so the people already show, U1 among them by its id.
      assert html =~ "Ana"
      assert html =~ "Bruno"
      assert html =~ "in #ops, D9"
      assert has_element?(view, "#native-channels-trainers input[value=U1][checked]")
      refute has_element?(view, "#native-channels-trainers input[value=U2][checked]")

      view
      |> form("form[phx-submit=save]", %{"trainers" => %{"people" => ["U2", "U3"], "extra" => "U8"}})
      |> render_submit()

      assert Config.get_webhook("desk")["trainers"] == ["U2", "U3", "U8"]
    end

    test "everyone, no one and the default are modes, and switching hides the people" do
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_edit(view)

      view |> form("form[phx-submit=save]", %{"trainers" => %{"mode" => "*"}}) |> render_change()
      refute has_element?(view, "#native-channels-trainers input[value=U2]")
      view |> form("form[phx-submit=save]", %{"trainers" => %{"mode" => "*"}}) |> render_submit()
      assert Config.get_webhook("desk")["trainers"] == ["*"]

      open_edit(view)
      view |> form("form[phx-submit=save]", %{"trainers" => %{"mode" => "none"}}) |> render_submit()
      assert Config.get_webhook("desk")["trainers"] == []

      # Default on an admin connection is no list at all (everyone may train).
      open_edit(view)
      view |> form("form[phx-submit=save]", %{"trainers" => %{"mode" => "default"}}) |> render_submit()
      refute Map.has_key?(Config.get_webhook("desk"), "trainers")
    end
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

  describe "labels" do
    test "a connection shows its label with the slug beside it, in the title and the confirmation, and can be cleared" do
      {:ok, view, html} = live(conn(), "/bots")
      assert html =~ "Remove connection desk?"

      view |> element("button[phx-click=rename][phx-value-slug=desk]") |> render_click()
      html = view |> form("form[phx-submit=save_label]", %{"label" => " Support Slack "}) |> render_submit()

      assert Config.get_webhook("desk")["label"] == "Support Slack"
      assert html =~ "Support Slack"
      assert html =~ "Remove connection Support Slack?"
      # The slug is still the id, shown small beside the label.
      assert html =~ "desk"

      view |> element("button[phx-click=rename][phx-value-slug=desk]") |> render_click()
      html = view |> element("button[phx-click=clear_label][phx-value-slug=desk]") |> render_click()
      refute Map.has_key?(Config.get_webhook("desk"), "label")
      assert html =~ "Remove connection desk?"
    end

    test "a channel row shows its label first, the provider's name as fallback, and can be cleared" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", name: "#ops", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      html = open_desk(view)
      assert html =~ "#ops"

      view |> element("#seen-desk button[phx-click=rename][phx-value-channel=C1]") |> render_click()
      html = view |> form("#seen-desk form[phx-submit=save_label]", %{"label" => "Operations"}) |> render_submit()
      assert html =~ "Operations"
      assert SeenChannels.get("desk", "C1").label == "Operations"

      view |> element("#seen-desk button[phx-click=rename][phx-value-channel=C1]") |> render_click()
      html = view |> element("#seen-desk button[phx-click=clear_label][phx-value-channel=C1]") |> render_click()
      refute html =~ "Operations"
      assert html =~ "#ops"
    end

    test "a person is renamed from the picker, and the label shows wherever the person is listed" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
      SeenPeople.touch("desk", "C1", "U2", name: "ana", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)
      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "list"}}) |> render_change()

      view |> element("#seen-desk button[phx-click=rename_person][phx-value-person=U2]") |> render_click()
      html = view |> element("#seen-desk-rename-person-0") |> render_submit(%{"person" => "U2", "label" => "Ana Lima"})

      assert SeenPeople.get("desk", "U2").label == "Ana Lima"
      assert html =~ "Ana Lima"

      # The connection form's picker shows the same label.
      view |> element("button[phx-click=edit][phx-value-slug=desk]") |> render_click()
      assert render(view) =~ "Ana Lima"

      view |> element("button[phx-click=cancel]") |> render_click()
      open_desk(view)
      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "list"}}) |> render_change()
      view |> element("#seen-desk button[phx-click=rename_person][phx-value-person=U2]") |> render_click()
      html = view |> element("#seen-desk button[phx-click=clear_person_label][phx-value-person=U2]") |> render_click()
      assert SeenPeople.get("desk", "U2").label == nil
      refute html =~ "Ana Lima"
      assert html =~ "ana"
    end

    test "a Telegram bot takes a label from its card and from its form, and is named by it everywhere" do
      {:ok, view, _html} = live(conn(), "/bots")

      view |> element("button[phx-click=bot_rename][phx-value-name=default]") |> render_click()
      html = view |> form("form[phx-submit=bot_save_label]", %{"label" => "Main bot"}) |> render_submit()
      assert Config.telegram_bot("default")["label"] == "Main bot"
      assert html =~ "Main bot"
      assert html =~ "Remove bot Main bot?"

      render_click(view, "bot_edit", %{"name" => "default"})
      html = view |> form("form[phx-submit=bot_save]", %{"label" => "", "token" => ""}) |> render_submit()
      refute Map.has_key?(Config.telegram_bot("default"), "label")
      assert html =~ "Bot default saved."
    end
  end

  describe "people pickers elsewhere" do
    test "who may message the connection is picked the same way, and anyone means nothing stored" do
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      view |> element("button[phx-click=edit][phx-value-slug=desk]") |> render_click()
      assert render(view) =~ "Who may message this connection"

      view |> form("form[phx-submit=save]", %{"allowed" => %{"mode" => "list"}}) |> render_change()
      assert has_element?(view, "#native-channels-allowed input[value=U2]")

      view |> form("form[phx-submit=save]", %{"allowed" => %{"people" => ["U2"], "extra" => "5511999"}}) |> render_submit()
      assert Config.get_webhook("desk")["allowed_numbers"] == ["U2", "5511999"]

      view |> element("button[phx-click=edit][phx-value-slug=desk]") |> render_click()
      assert has_element?(view, "#native-channels-allowed input[value=U2][checked]")
      view |> form("form[phx-submit=save]", %{"allowed" => %{"mode" => "default"}}) |> render_submit()
      refute Map.has_key?(Config.get_webhook("desk"), "allowed_numbers")
    end

    test "a Telegram bot's trainers are picked from the people who wrote to it, stored as integer ids" do
      SeenChannels.touch("default", "telegram", "-1001", kind: "group", name: "Ops team", now: @t0)
      SeenPeople.touch("default", "-1001", "55", name: "Ana Lima", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      render_click(view, "bot_edit", %{"name" => "default"})
      assert render(view) =~ "Who can train this bot"

      view |> form("form[phx-submit=bot_save]", %{"trainers" => %{"mode" => "list"}}) |> render_change()
      assert render(view) =~ "Ana Lima"
      assert has_element?(view, "#bot-trainers input[value='55']")

      view
      |> form("form[phx-submit=bot_save]", %{"token" => "", "trainers" => %{"people" => ["55"], "extra" => "66, nope"}})
      |> render_submit()

      assert Config.telegram_bot("default")["trainers"] == [55, 66]

      render_click(view, "bot_edit", %{"name" => "default"})
      assert has_element?(view, "#bot-trainers input[value='55'][checked]")
      view |> form("form[phx-submit=bot_save]", %{"token" => "", "trainers" => %{"mode" => "*"}}) |> render_submit()
      assert Config.telegram_bot("default")["trainers"] == ["*"]

      render_click(view, "bot_edit", %{"name" => "default"})
      view |> form("form[phx-submit=bot_save]", %{"token" => "", "trainers" => %{"mode" => "default"}}) |> render_submit()
      refute Map.has_key?(Config.telegram_bot("default"), "trainers")
    end

    test "each channel row lists only the people heard in that channel" do
      SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0 + 10)
      SeenChannels.touch("desk", "slack", "C2", kind: "group", now: @t0)
      SeenPeople.touch("desk", "C1", "U2", name: "Ana", now: @t0)
      SeenPeople.touch("desk", "C2", "U3", name: "Bruno", now: @t0)

      {:ok, view, _html} = live(conn(), "/bots")
      open_desk(view)
      view |> form("#seen-desk-trainers-0", %{"trainers" => %{"mode" => "list"}}) |> render_change()
      view |> form("#seen-desk-trainers-1", %{"trainers" => %{"mode" => "list"}}) |> render_change()

      assert has_element?(view, "#seen-desk-trainers-0 input[value=U2]")
      refute has_element?(view, "#seen-desk-trainers-0 input[value=U3]")
      assert has_element?(view, "#seen-desk-trainers-1 input[value=U3]")
      refute has_element?(view, "#seen-desk-trainers-1 input[value=U2]")
    end

    test "people with a name come first alphabetically, then ids by recency, and an empty list says so" do
      SeenPeople.touch("desk", "C1", "U9", now: @t0 + 5)
      SeenPeople.touch("desk", "C1", "U8", now: @t0 + 9)
      SeenPeople.touch("desk", "C1", "U2", name: "zoe", now: @t0)
      SeenPeople.touch("desk", "C1", "U3", name: "Bruno", now: @t0 + 20)

      assert ["U3", "U2", "U8", "U9"] = PepeWeb.TrainersPicker.people("desk") |> Enum.map(& &1.id)

      Config.put_webhook("empty", %{"provider" => "slack", "agent" => "default/assistant", "mode" => "admin", "config" => %{}})
      {:ok, view, _html} = live(conn(), "/bots")
      view |> element("button[phx-click=edit][phx-value-slug=empty]") |> render_click()
      view |> form("form[phx-submit=save]", %{"trainers" => %{"mode" => "list"}}) |> render_change()
      assert render(view) =~ "Nobody has written here yet. Add an id below."
    end
  end

  test "removing a connection forgets its channels and its people" do
    SeenChannels.touch("desk", "slack", "C1", kind: "group", now: @t0)
    SeenPeople.touch("desk", "C1", "U2", now: @t0)

    {:ok, view, _html} = live(conn(), "/bots")
    view |> element("button[phx-click=delete][phx-value-slug=desk]") |> render_click()

    assert SeenChannels.list("desk") == []
    assert SeenPeople.list("desk") == []
  end
end
