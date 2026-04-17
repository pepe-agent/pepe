defmodule PepeWeb.ModelsLiveFallbackTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_modelsui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a"})
    Config.put_model(%Model{name: "backup-a", base_url: "https://x", model: "gpt-b"})
    Config.put_model(%Model{name: "backup-b", base_url: "https://x", model: "gpt-c"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open_edit(view), do: render_click(view, "model_edit", %{"name" => "primary"})

  test "the fallback candidate list excludes the connection itself" do
    {:ok, view, _html} = live(conn(), "/models")
    html = open_edit(view)

    refute html =~ ~s(<option value="primary")
    assert html =~ ~s(<option value="backup-a")
    assert html =~ ~s(<option value="backup-b")
  end

  test "adding a fallback shows it as a chip and removes it from the dropdown" do
    {:ok, view, _html} = live(conn(), "/models")
    open_edit(view)

    html = render_change(view, "fallback_add", %{"fallback_candidate" => "backup-a"})
    assert html =~ "backup-a"
    refute html =~ ~s(<option value="backup-a")
    assert html =~ ~s(<option value="backup-b")
  end

  test "order is preserved and move up/down swaps position" do
    {:ok, view, _html} = live(conn(), "/models")
    open_edit(view)

    render_change(view, "fallback_add", %{"fallback_candidate" => "backup-a"})
    html = render_change(view, "fallback_add", %{"fallback_candidate" => "backup-b"})

    assert Regex.run(~r/backup-a.*backup-b/s, html)

    html = render_click(view, "fallback_move", %{"name" => "backup-b", "dir" => "up"})
    assert Regex.run(~r/backup-b.*backup-a/s, html)
  end

  test "remove drops it from the chip list and back into the dropdown" do
    {:ok, view, _html} = live(conn(), "/models")
    open_edit(view)

    render_change(view, "fallback_add", %{"fallback_candidate" => "backup-a"})
    html = render_click(view, "fallback_remove", %{"name" => "backup-a"})

    assert html =~ ~s(<option value="backup-a")
  end

  test "saving persists the fallback chain, in order, on the model connection" do
    {:ok, view, _html} = live(conn(), "/models")
    open_edit(view)

    render_change(view, "fallback_add", %{"fallback_candidate" => "backup-b"})
    render_change(view, "fallback_add", %{"fallback_candidate" => "backup-a"})

    view
    |> form("form[phx-submit=model_save]", %{
      "name" => "primary",
      "base_url" => "https://x",
      "model" => "gpt-a"
    })
    |> render_submit()

    assert Config.get_model("primary").fallbacks == ["backup-b", "backup-a"]
  end

  test "a save that doesn't touch fallbacks keeps the existing chain" do
    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a", fallbacks: ["backup-a"]})

    {:ok, view, _html} = live(conn(), "/models")
    open_edit(view)

    view
    |> form("form[phx-submit=model_save]", %{
      "name" => "primary",
      "base_url" => "https://x",
      "model" => "gpt-a"
    })
    |> render_submit()

    assert Config.get_model("primary").fallbacks == ["backup-a"]
  end
end
