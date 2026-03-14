defmodule PepeWeb.HooksLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_hooks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi", hooks: ["pii_redact"]})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "lists the four hooks and shows which agent uses one" do
    {:ok, _view, html} = live(conn(), "/hooks")

    assert html =~ "Regex redaction"
    assert html =~ "Model redaction"
    assert html =~ "HTTP redaction"
    assert html =~ "Presidio"
    # the agent from setup uses pii_redact
    assert html =~ "assistant"
  end

  test "configuring pii_redact persists the settings" do
    {:ok, view, _html} = live(conn(), "/hooks")

    # open the regex redactor's form
    render_click(view, "edit", %{"name" => "pii_redact"})

    # save with a Brazilian pack + a custom pattern + reversible on
    view
    |> form("form[phx-submit=save]", %{
      "packs" => ["br"],
      "recognizers" => ["email"],
      "custom" => "ticket|TK-\\d+|TICKET",
      "reversible" => "true"
    })
    |> render_submit()

    settings = Config.hook_settings("pii_redact")
    assert "br" in settings["packs"]
    assert "email" in settings["recognizers"]
    assert settings["reversible"] == true

    assert [%{"name" => "ticket", "pattern" => "TK-\\d+", "replace" => "TICKET"}] =
             settings["custom"]
  end

  test "an invalid custom regex is dropped on save" do
    {:ok, view, _html} = live(conn(), "/hooks")
    render_click(view, "edit", %{"name" => "pii_redact"})

    view
    |> form("form[phx-submit=save]", %{"custom" => "bad|(unclosed|X", "reversible" => "true"})
    |> render_submit()

    assert Config.hook_settings("pii_redact")["custom"] in [nil, []]
  end

  test "configuring presidio persists URLs and a numeric threshold" do
    {:ok, view, _html} = live(conn(), "/hooks")
    render_click(view, "edit", %{"name" => "presidio"})

    view
    |> form("form[phx-submit=save]", %{
      "analyzer_url" => "http://localhost:5002/analyze",
      "anonymizer_url" => "http://localhost:5001/anonymize",
      "language" => "pt",
      "score_threshold" => "0.6"
    })
    |> render_submit()

    s = Config.hook_settings("presidio")
    assert s["analyzer_url"] == "http://localhost:5002/analyze"
    assert s["score_threshold"] == 0.6
  end
end
