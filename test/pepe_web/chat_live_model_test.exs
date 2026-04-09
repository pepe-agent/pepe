defmodule PepeWeb.ChatLiveModelTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "model-a", base_url: "https://x", model: "gpt-a"})
    Config.put_model(%Model{name: "model-b", base_url: "https://x", model: "gpt-b"})
    Config.put_agent(%Agent{name: "assistant", model: "model-a"})
    Config.set_default_agent("assistant")

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, key: "web:test-#{System.unique_integer([:positive])}"}
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp send_text(view, text) do
    view |> form("form[phx-submit=send]", %{"text" => text}) |> render_submit()
  end

  test "/models lists this scope's models", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/models")
    assert html =~ "model-a"
    assert html =~ "model-b"
  end

  test "/model with no args shows the current model", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/model")
    assert html =~ "gpt-a"
  end

  test "/model NAME with no scope asks to confirm session or global", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/model model-b")
    assert html =~ "this conversation only"
    # nothing changed yet
    assert Config.get_agent("assistant").model == "model-a"
  end

  test "/model NAME session overrides just this tab, not the agent", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/model model-b session")
    assert html =~ "Model set to model-b"
    assert Config.get_agent("assistant").model == "model-a"
    assert Pepe.Agent.Session.status(key).model == "gpt-b"
  end

  test "/model NAME global persists the change on the agent", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/model model-b global")
    assert html =~ "Model set to model-b"
    assert Config.get_agent("assistant").model == "model-b"
  end

  test "/model with an unknown name is refused", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "/model ghost")
    assert html =~ "Unknown model"
    assert Config.get_agent("assistant").model == "model-a"
  end
end
