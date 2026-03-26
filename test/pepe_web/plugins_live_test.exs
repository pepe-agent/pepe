defmodule PepeWeb.PluginsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_pluginsui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "install requires confirming trust, then installs from a local path" do
    {:ok, view, html} = live(conn(), "/plugins")
    assert html =~ "No plugins installed"
    assert html =~ "full access"

    # without confirming trust, install is refused
    view |> form("form[phx-submit=install]", %{src: "examples/plugins/chatwoot"}) |> render_submit()
    assert render(view) =~ "Confirm you trust"
    assert Pepe.Plugins.packages() == []

    # confirm trust, then it installs
    render_click(view, "toggle_trust")
    view |> form("form[phx-submit=install]", %{src: "examples/plugins/chatwoot"}) |> render_submit()
    html = render_async(view)

    assert html =~ "chatwoot"
    assert "chatwoot" in Pepe.Webhooks.providers()
  end

  test "refuses a dangerous plugin and offers to install anyway" do
    danger = Path.join(System.tmp_dir!(), "evil_ui_#{System.unique_integer([:positive])}.exs")

    File.write!(danger, """
    defmodule EvilUi do
      def run, do: System.cmd("sh", ["-c", "boom"])
    end
    """)

    on_exit(fn -> File.rm(danger) end)

    {:ok, view, _} = live(conn(), "/plugins")
    render_click(view, "toggle_trust")
    view |> form("form[phx-submit=install]", %{src: danger}) |> render_submit()
    html = render_async(view)

    assert html =~ "danger"
    assert html =~ "Install anyway"
    assert Pepe.Plugins.packages() == []

    # force it through
    render_click(view, "install_force")
    render_async(view)
    assert Pepe.Plugins.packages() != []
  end

  test "a plugin that declares config fields can be configured from the dashboard" do
    {:ok, view, _} = live(conn(), "/plugins")
    render_click(view, "toggle_trust")
    view |> form("form[phx-submit=install]", %{src: "examples/plugins/google"}) |> render_submit()
    html = render_async(view)

    # the manifest declares config, so a Configure button shows
    assert html =~ "google"
    assert html =~ "Configure"

    # open the settings and save a token
    render_click(view, "configure", %{"name" => "google"})

    view
    |> form("form[phx-submit=settings_save]", %{"cfg" => %{"access_token" => "${GOOGLE_TOKEN}"}})
    |> render_submit()

    assert Pepe.Config.plugin_config("google")["access_token"] == "${GOOGLE_TOKEN}"
  end
end
