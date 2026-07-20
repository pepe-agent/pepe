defmodule PepeWeb.ChatLiveMarkdownTest do
  @moduledoc """
  A chat message can carry real markdown (a table, a list, ...) regardless of surface -
  Telegram, the API, or an agent's own reply all deliver it with real newlines intact; only
  the dashboard's own single-line compose `<input>` can't produce one (HTML strips newlines
  from a text input's value). `render_submit/1` sends the event params directly, the same way
  those other surfaces would, sidestepping that unrelated input-widget limitation.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatmd_#{System.unique_integer([:positive])}")
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

  defp send_text(view, text) do
    view |> form("form[phx-submit=send]", %{"text" => text}) |> render_submit()
  end

  test "a GFM table renders as a real <table>, not literal pipes", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    table = """
    | Bloco | Exemplo |
    |---|---|
    | Contexto | SETOR - 2K limita o fluxo |
    """

    html = send_text(view, table)

    assert html =~ "<table>"
    assert html =~ "<th>Bloco</th>"
    assert html =~ "<td>Contexto</td>"
    refute html =~ "|---|---|"
  end

  test "a list renders as <ul><li>, and inline bold/code still work", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "**bold**, `code`, and:\n- one\n- two")

    assert html =~ "<strong>bold</strong>"
    assert html =~ "<code>code</code>"
    assert html =~ "<li>one</li>"
    assert html =~ "<li>two</li>"
  end

  test "raw HTML in a message is escaped, never executed", %{key: key} do
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")

    html = send_text(view, "<script>alert(1)</script>")

    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end
end
