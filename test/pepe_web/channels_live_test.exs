defmodule PepeWeb.ChannelsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_channelsui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "assistant"})
    Config.put_agent(%Agent{name: "sales"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  # Every bot here is configured with an env-var reference that is deliberately not
  # exported, so the token never resolves: the poller stays inactive and no test ever
  # reaches out to Telegram.
  defp add_bot(view, params) do
    render_click(view, "add", %{"kind" => "bot"})

    view
    |> form("form[phx-submit=bot_add]", %{"bot" => params})
    |> render_submit()
  end

  defp add_widget(view, params) do
    render_click(view, "add", %{"kind" => "widget"})

    view
    |> form("form[phx-submit=widget_add]", %{"widget" => params})
    |> render_submit()
  end

  defp bot_names, do: Config.telegram_bots() |> Enum.map(& &1["name"])

  # The embed snippet is rendered as text, so its quotes come back HTML-escaped:
  # read it as text to assert on the snippet the operator actually copies.
  defp snippet_text(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("pre") |> LazyHTML.text()
  end

  test "the empty page offers a channel for every supported platform" do
    {:ok, _view, html} = live(conn(), "/bots")

    assert html =~ "Add a channel"
    assert html =~ "Telegram bot"
    assert html =~ "Widget"
  end

  test "adding a Telegram bot persists it, bound to its agent, and lists it" do
    {:ok, view, _html} = live(conn(), "/bots")

    html =
      add_bot(view, %{"name" => "sales-bot", "token" => "${SALES_BOT_TOKEN}", "agent" => "default/sales"})

    assert html =~ "Bot sales-bot added."
    assert html =~ "sales-bot"
    assert html =~ "${SALES_BOT_TOKEN}"

    bot = Config.telegram_bot("sales-bot")
    assert bot["bot_token"] == "${SALES_BOT_TOKEN}"
    assert bot["agent"] == "default/sales"
  end

  test "a bot with no name or token is refused" do
    {:ok, view, _html} = live(conn(), "/bots")

    html = add_bot(view, %{"name" => "", "token" => ""})

    assert html =~ "Please fix the errors below."
    assert bot_names() == ["default"]
  end

  test "a bot may not be named default, which is the legacy single-bot slot" do
    {:ok, view, _html} = live(conn(), "/bots")

    html = add_bot(view, %{"name" => "default", "token" => "${OTHER_TOKEN}"})

    assert html =~ "pick another name"
    assert bot_names() == ["default"]
    assert Config.telegram_bot("default")["bot_token"] == "${TELEGRAM_BOT_TOKEN}"
  end

  test "a second bot may not reuse another bot's token" do
    {:ok, view, _html} = live(conn(), "/bots")

    add_bot(view, %{"name" => "sales-bot", "token" => "${SHARED_TOKEN}", "agent" => "default/sales"})

    html =
      add_bot(view, %{"name" => "support-bot", "token" => "${SHARED_TOKEN}", "agent" => "default/assistant"})

    assert html =~ "this token is already used by another bot"
    assert Config.telegram_bot("support-bot") == nil
    assert bot_names() == ["default", "sales-bot"]
  end

  test "editing a bot rebinds its agent and keeps the token when left blank" do
    {:ok, view, _html} = live(conn(), "/bots")

    add_bot(view, %{"name" => "sales-bot", "token" => "${SALES_BOT_TOKEN}", "agent" => "default/sales"})

    render_click(view, "bot_edit", %{"name" => "sales-bot"})

    html =
      view
      |> form("form[phx-submit=bot_save]", %{"agent" => "default/assistant", "token" => ""})
      |> render_submit()

    assert html =~ "Bot sales-bot saved."
    bot = Config.telegram_bot("sales-bot")
    assert bot["agent"] == "default/assistant"
    assert bot["bot_token"] == "${SALES_BOT_TOKEN}"
  end

  test "a bot edit may not steal another bot's token" do
    {:ok, view, _html} = live(conn(), "/bots")

    add_bot(view, %{"name" => "sales-bot", "token" => "${SALES_TOKEN}", "agent" => "default/sales"})
    add_bot(view, %{"name" => "support-bot", "token" => "${SUPPORT_TOKEN}", "agent" => "default/assistant"})

    render_click(view, "bot_edit", %{"name" => "support-bot"})

    html =
      view
      |> form("form[phx-submit=bot_save]", %{"agent" => "default/assistant", "token" => "${SALES_TOKEN}"})
      |> render_submit()

    assert html =~ "That token is already used by another bot."
    assert Config.telegram_bot("support-bot")["bot_token"] == "${SUPPORT_TOKEN}"
  end

  test "removing a bot drops it from the config and from the page" do
    {:ok, view, _html} = live(conn(), "/bots")

    add_bot(view, %{"name" => "sales-bot", "token" => "${SALES_BOT_TOKEN}", "agent" => "default/sales"})
    assert has_element?(view, "button[phx-click=bot_edit][phx-value-name=sales-bot]")

    render_click(view, "bot_remove", %{"name" => "sales-bot"})

    assert Config.telegram_bot("sales-bot") == nil
    refute has_element?(view, "button[phx-click=bot_edit][phx-value-name=sales-bot]")
  end

  test "the bot list only shows the selected project's bots" do
    :ok = Config.add_project("acme")
    Config.put_agent(%Agent{name: "acme/support"})

    {:ok, view, _html} = live(conn(), "/bots")
    add_bot(view, %{"name" => "root-bot", "token" => "${ROOT_TOKEN}", "agent" => "default/assistant"})
    add_bot(view, %{"name" => "acme-bot", "token" => "${ACME_TOKEN}", "agent" => "acme/support"})

    {:ok, _view, html} = live(conn(), "/bots?scope=acme")
    assert html =~ "acme-bot"
    refute html =~ "root-bot"

    {:ok, _view, html} = live(conn(), "/bots?scope=default")
    assert html =~ "root-bot"
    refute html =~ "acme-bot"
  end

  test "adding a widget mints an agent-locked token and shows the embed snippet" do
    {:ok, view, _html} = live(conn(), "/bots")

    html =
      add_widget(view, %{
        "label" => "example.com widget",
        "agent" => "default/sales",
        "allowed_origin" => "https://example.com",
        "title" => "Chat with us"
      })

    assert [token] = Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget"))
    assert token["agent"] == "default/sales"
    assert token["allowed_origin"] == "https://example.com"
    assert token["title"] == "Chat with us"

    assert html =~ "Widget created"
    assert html =~ "example.com widget"

    snippet = snippet_text(html)
    assert snippet =~ "widget.js"
    assert snippet =~ ~s(data-token="#{token["token"]}")
    assert snippet =~ ~s(data-title="Chat with us")
  end

  test "a widget with no agent is refused" do
    {:ok, view, _html} = live(conn(), "/bots")

    html = add_widget(view, %{"label" => "orphan", "agent" => ""})

    assert html =~ "Pick an agent for this widget."
    assert Config.api_tokens() == []
  end

  test "a widget's appearance can be changed after it is minted" do
    {:ok, view, _html} = live(conn(), "/bots")

    add_widget(view, %{"agent" => "default/sales", "title" => "Chat"})
    [token] = Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget"))

    render_click(view, "widget_dismiss")
    render_click(view, "widget_edit", %{"id" => token["id"]})

    html =
      view
      |> form("form[phx-submit=widget_edit_save]", %{
        "widget_id" => token["id"],
        "widget_edit" => %{"title" => "Support", "theme" => "dark"}
      })
      |> render_submit()

    [updated] = Config.api_tokens() |> Enum.filter(&(&1["kind"] == "widget"))
    assert updated["title"] == "Support"
    assert updated["theme"] == "dark"
    # The token itself is untouched: appearance is the only thing this form edits.
    assert updated["agent"] == "default/sales"
    assert snippet_text(html) =~ ~s(data-title="Support")
  end

  describe "user approval" do
    # Turning the checkbox on is a form submit (bot_save), same as any other field.
    defp enable_approval(view) do
      view
      |> form("form[phx-submit=bot_save]", %{"require_approval" => "true"})
      |> render_submit()
    end

    test "the panel is nested under the checkbox, inside the form, and Add/Ignore never submit it" do
      {:ok, view, _html} = live(conn(), "/bots")
      render_click(view, "bot_edit", %{"name" => "default"})

      # bot_save (like any other field's save) closes the edit form, so reopen it to see the panel.
      enable_approval(view)
      html = render_click(view, "bot_edit", %{"name" => "default"})
      assert html =~ "No one is waiting."

      Config.add_telegram_pending("default", %{"id" => 555, "name" => "Salvador", "chat_id" => -1, "at" => 0, "sample" => "oi"})
      html = render_click(view, "bot_edit", %{"name" => "default"})
      assert html =~ "Salvador"
      assert html =~ "id 555"

      # Add is a real button inside <form phx-submit="bot_save">. Without type="button" a plain
      # <button> defaults to type="submit" and clicking it would also re-run bot_save - asserting
      # bot_save's own side effect (its flash) never fired proves that didn't happen.
      html = render_click(view, "bot_approve_user", %{"name" => "default", "id" => "555"})
      refute html =~ "Bot default saved."
      assert Config.telegram_bot("default")["allowed_users"] == [555]
      assert html =~ "No one is waiting."
      # Salvador moved from "waiting" to "allowed" - still on the page, under the other panel.
      assert html =~ "Allowed users"
    end

    test "Ignore drops a pending user without allowing them" do
      {:ok, view, _html} = live(conn(), "/bots")
      render_click(view, "bot_edit", %{"name" => "default"})
      enable_approval(view)

      Config.add_telegram_pending("default", %{"id" => 777, "name" => "Ana", "chat_id" => -1, "at" => 0, "sample" => "oi"})
      render_click(view, "bot_edit", %{"name" => "default"})

      html = render_click(view, "bot_dismiss_user", %{"name" => "default", "id" => "777"})
      assert Config.telegram_pending("default") == []
      refute 777 in (Config.telegram_bot("default")["allowed_users"] || [])
      assert html =~ "No one is waiting."
    end

    test "the panel only shows once the checkbox is on" do
      {:ok, view, _html} = live(conn(), "/bots")
      html = render_click(view, "bot_edit", %{"name" => "default"})

      refute html =~ "Waiting for approval"
      refute html =~ "Allowed users"
    end

    test "an approved user shows up under Allowed users, with the name captured from the queue, and can be revoked" do
      {:ok, view, _html} = live(conn(), "/bots")
      render_click(view, "bot_edit", %{"name" => "default"})
      enable_approval(view)
      render_click(view, "bot_edit", %{"name" => "default"})

      Config.add_telegram_pending("default", %{"id" => 999, "name" => "Beto", "chat_id" => -1, "at" => 0, "sample" => "oi"})
      render_click(view, "bot_edit", %{"name" => "default"})
      render_click(view, "bot_approve_user", %{"name" => "default", "id" => "999"})

      html = render_click(view, "bot_edit", %{"name" => "default"})
      assert html =~ "Beto"
      assert html =~ "id 999"
      refute html =~ "No one has been approved yet."

      html = render_click(view, "bot_revoke_user", %{"name" => "default", "id" => "999"})
      assert Config.telegram_bot("default")["allowed_users"] == []
      assert html =~ "No one has been approved yet."
      refute html =~ "Beto"
    end

    test "an id added by hand (no queue history) shows with no name, not a crash" do
      Config.update_telegram_bot("default", &Map.put(&1, "allowed_users", [4242]))

      {:ok, view, _html} = live(conn(), "/bots")
      render_click(view, "bot_edit", %{"name" => "default"})
      html = enable_approval(view)
      html = html <> render_click(view, "bot_edit", %{"name" => "default"})

      assert html =~ "id 4242"
      assert html =~ "no name on record"
    end
  end

  test "restarting the gateway reports back to the operator" do
    {:ok, view, _html} = live(conn(), "/bots")

    assert render_click(view, "restart_gateway") =~ "Telegram gateway restarted."
  end

  # A fresh config is seeded with the legacy singular `telegram` map so that exporting
  # TELEGRAM_BOT_TOKEN is enough to get a bot with nothing else to set up. The dashboard
  # rendered that seed as a bot card the operator never created, and hid its remove button,
  # because removing it would not have worked: delete_telegram_bot/1 only ever touched the
  # `telegrams` map, and the seed is not in it.
  describe "the seeded default bot" do
    test "shows up on a fresh install and can be dismissed" do
      {:ok, view, html} = live(conn(), "/bots")

      assert html =~ "default"
      assert render_click(view, "bot_remove", %{"name" => "default"})

      refute Enum.any?(Pepe.Config.telegram_bots(), &(&1["name"] == "default"))
      refute render(view) =~ "bot_remove"
    end

    test "removing it does not disturb a bot the operator did create" do
      {:ok, view, _} = live(conn(), "/bots")
      add_bot(view, %{"name" => "support", "token" => "t", "agent" => "default/assistant"})

      render_click(view, "bot_remove", %{"name" => "default"})

      names = Enum.map(Pepe.Config.telegram_bots(), & &1["name"])
      assert "support" in names
      refute "default" in names
    end
  end
end
