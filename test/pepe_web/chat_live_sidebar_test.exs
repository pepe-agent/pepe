defmodule PepeWeb.ChatLiveSidebarTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_sidebar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "model-a", base_url: "https://x", model: "gpt-a"})
    Config.put_agent(%Agent{name: "assistant", model: "model-a"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "web:test-#{System.unique_integer([:positive])}"}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "the sidebar shows the raw session key under the title", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    view |> form("form[phx-submit=send]", %{"text" => "oi"}) |> render_submit()

    {:ok, _sidebar, html} = live(conn(), "/chat")

    assert html =~ key
  end
end
