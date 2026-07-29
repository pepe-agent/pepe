defmodule PepeWeb.TokensLiveTest do
  @moduledoc """
  Minting and re-permissioning tokens from the dashboard.

  The regression this file exists for: the create form hides the whole permissions block in
  widget mode, and the handler read those (absent) checkboxes anyway - turning every one into
  an explicit `false` and refusing the token as good for nothing. It went unnoticed because
  nothing covered this LiveView at all.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.ApiToken
  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_tokens_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "assistant"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp only_token, do: Config.api_tokens() |> List.first()

  # Params are pushed directly rather than through `form/3` because what is under test is
  # exactly *which keys the browser sends*: a hidden checkbox posts nothing, and `form/3`
  # would helpfully fill in the rendered defaults and hide the very thing that broke.
  test "a widget token can still be minted, though its form shows no permissions" do
    {:ok, view, _html} = live(conn(), "/tokens")

    html =
      render_submit(view, "token_create", %{
        "widget" => "true",
        "agent" => "default/assistant",
        "allowed_origin" => "https://example.com"
      })

    assert html =~ "Copy it now"
    token = only_token()
    assert token["kind"] == "widget"
    # It keeps the defaults it never got asked about: chat on, usage off.
    assert ApiToken.permissions(token) == %{chat: true, usage: false, prices: "billable", usage_content: false}
  end

  test "a plain token minted with the defaults stores no permission fields at all" do
    {:ok, view, _html} = live(conn(), "/tokens")

    render_submit(view, "token_create", %{"label" => "app", "chat" => "true", "prices" => "billable"})

    token = only_token()
    refute Map.has_key?(token, "chat")
    refute Map.has_key?(token, "usage")
    # Not even the default price view: the entry only ever carries what differs.
    refute Map.has_key?(token, "prices")
  end

  test "a read-only billing token is minted with exactly what was ticked" do
    {:ok, view, _html} = live(conn(), "/tokens")

    render_submit(view, "token_create", %{"label" => "billing", "usage" => "true", "prices" => "list"})

    perms = ApiToken.permissions(only_token())
    refute perms.chat
    assert perms.usage
    assert perms.prices == "list"
  end

  test "leaving a token able to do nothing is refused, with a reason" do
    {:ok, view, _html} = live(conn(), "/tokens")

    # Neither box ticked: the browser posts neither key.
    html = render_submit(view, "token_create", %{"label" => "dead"})

    assert html =~ "able to do nothing"
    assert Config.api_tokens() == []
  end

  test "narrowing an existing token's price view takes effect, secret untouched" do
    {:ok, _raw, id} = Config.add_api_token(label: "client", usage: true, prices: "all")
    hash = only_token()["hash"]

    {:ok, view, _html} = live(conn(), "/tokens")

    render_submit(view, "token_permissions", %{
      "token_id" => id,
      "chat" => "true",
      "usage" => "true",
      "prices" => "billable"
    })

    assert ApiToken.permissions(only_token()).prices == "billable"
    assert only_token()["hash"] == hash
  end

  test "a widget token is refused the billing record even if the form is forged" do
    {:ok, _raw, id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    {:ok, view, _html} = live(conn(), "/tokens")

    html =
      render_submit(view, "token_permissions", %{"token_id" => id, "chat" => "true", "usage" => "true"})

    assert html =~ "public page source"
    refute ApiToken.permissions(only_token()).usage
  end
end
