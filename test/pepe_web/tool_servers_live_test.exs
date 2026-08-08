defmodule PepeWeb.ToolServersLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_mcplive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open_form(view) do
    view |> element("button", "+ New server") |> render_click()
    view
  end

  test "the transport select offers exactly what Pepe.MCP.Transport accepts" do
    {:ok, view, _html} = live(conn(), "/mcp")
    html = open_form(view)

    for choice <- Pepe.MCP.Transport.choices() do
      assert html |> render() =~ ~s(value="#{choice}")
    end
  end

  test "saving a remote server persists the chosen transport" do
    {:ok, view, _html} = live(conn(), "/mcp")

    view
    |> open_form()
    |> form("#mcp-form",
      mcp: %{
        "name" => "legacy",
        "kind" => "remote",
        "url" => "https://mcp.example.com/sse",
        "transport" => "sse",
        "headers" => ""
      }
    )
    |> render_submit()

    assert %{"transport" => "sse", "url" => "https://mcp.example.com/sse"} =
             Config.mcp_servers()["legacy"]
  end

  test "a transport the backend doesn't know falls back to auto instead of being stored" do
    {:ok, view, _html} = live(conn(), "/mcp")

    # Straight at the event, not through the form: the <select> itself won't offer this,
    # which is the point - a crafted payload still can't write a value nothing can start.
    render_click(open_form(view), "mcp_save", %{
      "mcp" => %{
        "name" => "weird",
        "kind" => "remote",
        "url" => "https://x.test/mcp",
        "transport" => "carrier-pigeon"
      }
    })

    assert Config.mcp_servers()["weird"]["transport"] == "auto"
  end

  test "the error banner waits for a submit instead of firing on the first keystroke" do
    {:ok, view, _html} = live(conn(), "/mcp")
    view = open_form(view)

    typing =
      view
      |> form("#mcp-form", mcp: %{"name" => "s", "kind" => "remote", "url" => ""})
      |> render_change()

    refute typing =~ "Please fix the errors below."

    submitted =
      view
      |> form("#mcp-form", mcp: %{"name" => "s", "kind" => "remote", "url" => ""})
      |> render_submit()

    assert submitted =~ "Please fix the errors below."
  end

  test "editing loads the server into the form and keeps its pinned OAuth client" do
    Config.put_mcp_server("sentry", %{
      "url" => "https://mcp.sentry.dev/mcp",
      "headers" => %{"Authorization" => "Bearer ${SENTRY_TOKEN}"},
      "transport" => "auto",
      "oauth" => %{"client_id" => "pinned-123"}
    })

    {:ok, view, _html} = live(conn(), "/mcp")

    editing = view |> element("button[phx-value-name=sentry]", "Edit") |> render_click()

    assert editing =~ "Edit MCP server"
    assert editing =~ "https://mcp.sentry.dev/mcp"
    assert editing =~ "Bearer ${SENTRY_TOKEN}"

    view
    |> form("#mcp-form",
      mcp: %{
        "name" => "sentry",
        "kind" => "remote",
        "url" => "https://mcp.sentry.dev/mcp/fixed",
        "transport" => "streamable",
        "headers" => "Authorization: Bearer ${SENTRY_TOKEN}"
      }
    )
    |> render_submit()

    saved = Config.mcp_servers()["sentry"]
    assert saved["url"] == "https://mcp.sentry.dev/mcp/fixed"
    assert saved["transport"] == "streamable"
    assert saved["oauth"] == %{"client_id" => "pinned-123"}
  end

  test "renaming on edit moves the entry rather than leaving both" do
    Config.put_mcp_server("typo", %{"command" => "npx", "args" => ["-y", "thing"], "env" => %{"A" => "1"}})

    {:ok, view, _html} = live(conn(), "/mcp")
    view |> element("button[phx-value-name=typo]", "Edit") |> render_click()

    view
    |> form("#mcp-form", mcp: %{"name" => "fixed", "kind" => "local", "command" => "npx", "args" => "-y thing"})
    |> render_submit()

    servers = Config.mcp_servers()
    refute Map.has_key?(servers, "typo")
    assert servers["fixed"]["args"] == ["-y", "thing"]
    assert servers["fixed"]["env"] == %{"A" => "1"}
  end
end
