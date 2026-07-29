defmodule PepeWeb.UsageLiveRunsTest do
  @moduledoc """
  The per-message table on the Usage page: one row per inbound message, expandable into the
  several model calls it actually took.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.Usage.Log
  alias Pepe.Usage.Runs

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_usage_runs_ui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_model(%Model{name: "mock", base_url: "http://x", api_key: "k", model: "m", input_price: 1.0, output_price: 2.0})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp seed do
    at = 1_770_000_000

    Runs.record(%{
      id: "1000",
      scope: nil,
      at: at,
      agent: "assistant",
      session: "telegram:7",
      source: "telegram",
      ms: 4_210,
      outcome: %{"kind" => "ok"},
      events: [%{"t" => "tool_call", "name" => "web_search", "args" => "x"}]
    })

    for _ <- 1..2 do
      Log.append(nil, %{"at" => at, "agent" => "assistant", "model" => "mock", "in" => 10, "out" => 5, "run_id" => "1000"})
    end
  end

  test "an empty scope says so, without pretending the section is missing" do
    {:ok, _view, html} = live(conn(), "/usage")

    assert html =~ "No messages recorded yet for this scope."
  end

  test "lists a message with its source, tools and elapsed time" do
    seed()

    {:ok, _view, html} = live(conn(), "/usage")

    assert html =~ "telegram"
    assert html =~ "web_search"
    assert html =~ "4.2s"
  end

  test "opening a row shows the model calls behind that one message" do
    seed()

    {:ok, view, html} = live(conn(), "/usage")
    # Collapsed, the breakdown is not rendered at all - it is not loaded until asked for.
    refute html =~ "Every model call this message took"

    opened = view |> element("tr[phx-value-id='1000']") |> render_click()

    assert opened =~ "Every model call this message took"
    # Two calls behind one message: the point of the whole table.
    assert opened |> String.split("mock") |> length() >= 3
  end

  test "clicking the same row again closes it" do
    seed()

    {:ok, view, _html} = live(conn(), "/usage")
    view |> element("tr[phx-value-id='1000']") |> render_click()
    closed = view |> element("tr[phx-value-id='1000']") |> render_click()

    refute closed =~ "Every model call this message took"
  end
end
