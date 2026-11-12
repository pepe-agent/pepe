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
    assert html =~ "this one was saved as openrouter-2"
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

  defmodule PingPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    # `/bad/...` answers like a provider rejecting the key; anything else is a healthy completion.
    def call(%{request_path: "/bad" <> _} = conn, _opts) do
      body = Jason.encode!(%{"error" => %{"message" => "Incorrect API key provided"}})
      conn |> put_resp_content_type("application/json") |> send_resp(401, body)
    end

    def call(conn, _opts) do
      body = Jason.encode!(%{"choices" => [%{"message" => %{"role" => "assistant", "content" => "pong"}, "finish_reason" => "stop"}]})
      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  # The ping runs off the LiveView process, so its result lands a moment after the click.
  defp await_html(view, text, tries \\ 100) do
    html = render(view)

    cond do
      html =~ text -> html
      tries == 0 -> flunk("never rendered #{inspect(text)}:\n#{html}")
      true -> Process.sleep(50) && await_html(view, text, tries - 1)
    end
  end

  describe "testing a connection" do
    setup do
      server = start_supervised!({Bandit, plug: PingPlug, port: 0, scheme: :http})
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      %{base: "http://localhost:#{port}"}
    end

    test "a working connection reports that it works, with the round-trip time", %{base: base} do
      model_fixture("primary", %{base_url: base <> "/ok"})
      {:ok, view, html} = live(conn(), "/models")
      assert html =~ "Test"

      render_click(view, "model_test", %{"name" => "primary"})

      html = await_html(view, "Works")
      assert html =~ " ms"
      refute html =~ "Failed"
    end

    test "a rejected key shows Failed with the provider's own reason", %{base: base} do
      model_fixture("primary", %{base_url: base <> "/bad"})
      {:ok, view, _html} = live(conn(), "/models")

      render_click(view, "model_test", %{"name" => "primary"})

      html = await_html(view, "Failed")
      assert html =~ "HTTP 401: Incorrect API key provided"
    end

    test "an unreachable endpoint fails instead of hanging on Testing..." do
      # Nothing listens on port 1. Req retries a refused connection with backoff (1+2+4 s), so the
      # failure lands after ~7 s: allow for it.
      model_fixture("primary", %{base_url: "http://localhost:1"})
      {:ok, view, _html} = live(conn(), "/models")

      render_click(view, "model_test", %{"name" => "primary"})

      assert await_html(view, "Failed", 300) =~ "Failed"
    end

    test "testing one connection leaves the others untouched", %{base: base} do
      model_fixture("good", %{base_url: base <> "/ok"})
      model_fixture("other", %{base_url: base <> "/ok"})
      {:ok, view, _html} = live(conn(), "/models")

      render_click(view, "model_test", %{"name" => "good"})
      await_html(view, "Works")

      assert view |> element("[phx-click=model_test][phx-value-name=other]") |> render() =~ "Test"
      assert render(view) |> String.split("Works") |> length() == 2
    end

    test "a decision-only connection has no Test button" do
      model_fixture("jev", %{api: Pepe.Decide.Jev.api()})
      {:ok, view, _html} = live(conn(), "/models")

      refute has_element?(view, "[phx-click=model_test][phx-value-name=jev]")
    end

    test "testing a connection that no longer exists is a no-op" do
      {:ok, view, _html} = live(conn(), "/models")
      assert render_click(view, "model_test", %{"name" => "ghost"})
    end
  end
end
