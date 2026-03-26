defmodule PepeWeb.IntegrationsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_integrations_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # install the Chatwoot channel plugin so its provider shows up
    {:ok, "chatwoot", _} = Pepe.Plugins.install("examples/plugins/chatwoot")

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "lists the Chatwoot provider" do
    {:ok, _view, html} = live(conn(), "/integrations")
    assert html =~ "Chatwoot"
  end

  test "creating a connection persists a webhook entry and shows its URL" do
    {:ok, view, _html} = live(conn(), "/integrations")

    # open the new-connection form for Chatwoot (event lives on the shared component)
    view |> element("button[phx-value-name='chatwoot']") |> render_click()

    html =
      view
      |> form("form[phx-submit=save]", %{
        "slug" => "acme",
        "agent" => "assistant",
        "mode" => "support",
        "company" => "root",
        "cfg" => %{
          "base_url" => "https://app.chatwoot.com",
          "account_id" => "42",
          "api_token" => "${CHATWOOT_TOKEN}"
        }
      })
      |> render_submit()

    entry = Config.get_webhook("acme")
    assert entry["provider"] == "chatwoot"
    assert entry["agent"] == "assistant"
    assert entry["config"]["base_url"] == "https://app.chatwoot.com"
    assert entry["config"]["account_id"] == "42"
    assert entry["config"]["api_token"] == "${CHATWOOT_TOKEN}"

    # back on the list, the webhook URL is shown for pasting into the provider
    assert html =~ "/webhooks/"
    assert html =~ "chatwoot/acme"
  end
end
