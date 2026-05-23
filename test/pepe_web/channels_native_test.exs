defmodule PepeWeb.ChannelsNativeTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_native_ch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "the Channels page lists every native webhook channel, WhatsApp included" do
    {:ok, _view, html} = live(conn(), "/bots")

    for label <- ["WhatsApp", "Slack", "Discord", "Microsoft Teams", "Google Chat"] do
      assert html =~ label
    end
  end

  test "connecting WhatsApp goes through the same unified form" do
    {:ok, view, _html} = live(conn(), "/bots")

    view |> element("button[phx-value-name='whatsapp']") |> render_click()

    view
    |> form("form[phx-submit=save]", %{
      "slug" => "support",
      "agent" => "default/assistant",
      "mode" => "support",
      "project" => "default",
      "cfg" => %{"phone_number_id" => "123", "access_token" => "${WA_TOKEN}"}
    })
    |> render_submit()

    entry = Config.get_webhook("support")
    assert entry["provider"] == "whatsapp"
    assert entry["config"]["phone_number_id"] == "123"
    # support mode derives the customer-facing behaviour for every channel
    assert entry["ephemeral"] == true
    assert entry["trainers"] == []
  end

  test "connecting a Slack channel persists a webhook bound to its agent" do
    {:ok, view, _html} = live(conn(), "/bots")

    view |> element("button[phx-value-name='slack']") |> render_click()

    view
    |> form("form[phx-submit=save]", %{
      "slug" => "team",
      "agent" => "default/assistant",
      "mode" => "support",
      "project" => "default",
      "cfg" => %{"bot_token" => "xoxb-1", "signing_secret" => "${SLACK_SECRET}"}
    })
    |> render_submit()

    entry = Config.get_webhook("team")
    assert entry["provider"] == "slack"
    assert entry["agent"] == "default/assistant"
    assert entry["config"]["bot_token"] == "xoxb-1"
    assert entry["config"]["signing_secret"] == "${SLACK_SECRET}"
  end
end
