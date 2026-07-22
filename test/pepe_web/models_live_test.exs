defmodule PepeWeb.ModelsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_models_#{System.unique_integer([:positive])}")
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

  defp conn, do: %{build_conn() | host: "localhost"}

  defp model_fixture(name, attrs \\ %{}) do
    Config.put_model(struct(%Model{name: name, base_url: "https://x/v1", model: "gpt-a"}, attrs))
  end

  defp create(view, params) do
    render_click(view, "model_new")
    render_submit(view, "model_save", params)
  end

  test "connections are listed with their model id, endpoint and default badge" do
    model_fixture("primary", %{model: "gpt-5", base_url: "https://api.openai.com/v1"})
    model_fixture("backup", %{model: "claude-4"})
    Config.set_default_model("primary")

    {:ok, _view, html} = live(conn(), "/models")

    assert html =~ "primary"
    assert html =~ "gpt-5"
    assert html =~ "https://api.openai.com/v1"
    assert html =~ "backup"
    assert html =~ "default"
  end

  test "a connection is created with its prices and shows up in the list" do
    {:ok, view, _html} = live(conn(), "/models")

    html =
      create(view, %{
        "name" => "openai-main",
        "base_url" => "https://api.openai.com/v1",
        "model" => "gpt-5",
        "api_key" => "${OPENAI_API_KEY}",
        "input_price" => "1.25",
        "output_price" => "10"
      })

    assert html =~ "Model openai-main saved."
    assert html =~ "openai-main"

    model = Config.get_model("openai-main")
    assert model.base_url == "https://api.openai.com/v1"
    assert model.model == "gpt-5"
    assert model.api_key == "${OPENAI_API_KEY}"
    assert model.input_price == 1.25
    assert model.output_price == 10.0
  end

  test "a connection with no base URL or model id is refused" do
    {:ok, view, _html} = live(conn(), "/models")

    html = create(view, %{"name" => "openai-main", "base_url" => "", "model" => ""})

    assert html =~ "Name, base URL and model id are required."
    assert Config.models() == []
  end

  test "creating a connection never overwrites one with the same name" do
    model_fixture("openrouter", %{model: "gpt-a"})

    {:ok, view, _html} = live(conn(), "/models")

    html =
      create(view, %{
        "name" => "openrouter",
        "base_url" => "https://openrouter.ai/api/v1",
        "model" => "gpt-b"
      })

    # The existing connection survives untouched and the new one is suffixed.
    assert Config.get_model("openrouter").model == "gpt-a"
    assert Config.get_model("openrouter").base_url == "https://x/v1"
    assert Config.get_model("openrouter-2").model == "gpt-b"

    # And the operator is told why, in so many words. Asserting only that "openrouter-2"
    # appears would pass without the explanation, since the name is in the list either way:
    # the flash was in fact being built and then discarded by a second flash of the same
    # kind, leaving "Model openrouter-2 saved." and no hint where the -2 came from.
    assert html =~ "A model connection named openrouter already exists"
    assert html =~ "saved this one as openrouter-2 instead"
  end

  test "renaming a connection re-points the agents that use it" do
    model_fixture("primary")
    Config.put_agent(%Agent{name: "assistant", model: "primary"})

    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_edit", %{"name" => "primary"})

    html =
      view
      |> form("form[phx-submit=model_save]", %{
        "name" => "primary-eu",
        "base_url" => "https://x/v1",
        "model" => "gpt-a"
      })
      |> render_submit()

    assert html =~ "Model primary renamed to primary-eu and saved."
    assert Config.get_model("primary") == nil
    assert Config.get_model("primary-eu").model == "gpt-a"
    assert Config.get_agent("assistant").model == "primary-eu"
  end

  test "renaming onto an existing connection is refused and changes nothing" do
    model_fixture("primary", %{model: "gpt-a"})
    model_fixture("backup", %{model: "gpt-b"})

    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_edit", %{"name" => "primary"})

    html =
      view
      |> form("form[phx-submit=model_save]", %{
        "name" => "backup",
        "base_url" => "https://x/v1",
        "model" => "gpt-a"
      })
      |> render_submit()

    assert html =~ "A model connection named backup already exists."
    assert Config.get_model("primary").model == "gpt-a"
    assert Config.get_model("backup").model == "gpt-b"
  end

  test "requiring redaction on a provider is persisted" do
    model_fixture("primary")

    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_edit", %{"name" => "primary"})

    render_submit(view, "model_save", %{
      "original_name" => "primary",
      "name" => "primary",
      "base_url" => "https://x/v1",
      "model" => "gpt-a",
      "require_redaction" => "on"
    })

    assert Config.get_model("primary").require_redaction == true
  end

  test "setting a connection as the default moves the badge" do
    model_fixture("primary")
    model_fixture("backup")
    Config.set_default_model("primary")

    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_default", %{"name" => "backup"})

    assert Config.default_model_name() == "backup"
    assert has_element?(view, "button[phx-click=model_default][phx-value-name=primary]")
    refute has_element?(view, "button[phx-click=model_default][phx-value-name=backup]")
  end

  test "deleting a connection removes it from the config and from the list" do
    model_fixture("primary")
    model_fixture("backup")

    {:ok, view, _html} = live(conn(), "/models")

    html = render_click(view, "model_delete", %{"name" => "primary"})

    assert Config.get_model("primary") == nil
    refute html =~ "primary"
    assert html =~ "backup"
  end

  test "the list only shows the selected project's connections" do
    :ok = Config.add_project("acme")
    model_fixture("shared-openai")
    model_fixture("acme/private-openai")

    {:ok, _view, html} = live(conn(), "/models?scope=acme")
    assert html =~ "acme/private-openai"
    refute html =~ "shared-openai"

    {:ok, _view, html} = live(conn(), "/models?scope=root")
    assert html =~ "shared-openai"
    refute html =~ "acme/private-openai"
  end

  test "picking a provider fills the form in without clobbering a typed name" do
    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_new")
    html = render_change(view, "model_pick_provider", %{"provider" => "custom"})

    assert html =~ ~s(value="custom")
    assert html =~ ~s(name="base_url")
    assert html =~ "Loading models..."

    render_change(view, "model_name_change", %{"name" => "my-endpoint"})

    # The provider's model list lands asynchronously; it must not revert the field
    # back to the suggested name under the operator's fingers.
    send(view.pid, {:models_loaded, "custom", []})
    assert render(view) =~ ~s(value="my-endpoint")
  end

  test "clearing the provider resets the form" do
    {:ok, view, _html} = live(conn(), "/models")

    render_click(view, "model_new")
    render_change(view, "model_pick_provider", %{"provider" => "custom"})
    html = render_change(view, "model_pick_provider", %{"provider" => ""})

    refute html =~ "Loading models..."
    assert html =~ "Choose a provider..."
  end

  test "reconnecting a connection that isn't a subscription says so" do
    model_fixture("primary")

    {:ok, view, _html} = live(conn(), "/models")

    assert render_click(view, "oauth_reconnect", %{"name" => "primary"}) =~
             "a subscription connection."
  end
end
