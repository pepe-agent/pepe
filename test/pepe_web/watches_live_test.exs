defmodule PepeWeb.WatchesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Watch

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_watchui_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    Config.put_agent(%Agent{name: "assistant"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp put_watch(attrs) do
    watch =
      struct(
        %Watch{
          id: "w_#{System.unique_integer([:positive])}",
          description: "site is back",
          agent: "assistant",
          trigger: %{"type" => "probe", "command" => "curl -sf https://x"},
          origin: %{"channel" => "telegram", "chat_id" => 1},
          interval_s: 120,
          max_checks: 720,
          checks: 3,
          state: "pending"
        },
        attrs
      )

    {:ok, _} = Config.put_watch(watch)
    watch
  end

  test "the meta line is labelled and translated, not raw enum values" do
    put_watch(%{})

    {:ok, _view, html} = live(conn(), "/watches")

    assert html =~ "Waiting"
    refute html =~ ">pending<"
    assert html =~ "shell check"
    assert html =~ "every 2 minutes"
    refute html =~ "120s"
    assert html =~ "check 3 of 720, then it stops"
    assert html =~ "notifies on telegram"
  end

  test "an agent trigger says so" do
    put_watch(%{trigger: %{"type" => "agent", "prompt" => "has the deploy finished?"}})

    {:ok, _view, html} = live(conn(), "/watches")
    assert html =~ "asks the agent"
  end

  test "a failing watch shows its last error and its next check" do
    at = System.system_time(:second) + 120
    put_watch(%{last_error: "probe exited 7", next_check: at})

    {:ok, _view, html} = live(conn(), "/watches")

    assert html =~ "probe exited 7"
    assert html =~ "Next check"
  end

  test "terminal states explain themselves instead of just losing their buttons" do
    put_watch(%{state: "expired", description: "expired one"})
    put_watch(%{state: "done", description: "done one"})

    {:ok, _view, html} = live(conn(), "/watches")

    assert html =~ "Ran out of checks and stopped without firing."
    assert html =~ "This watch already fired and stopped."
    # A finished watch has no next check to advertise.
    refute html =~ "Next check"
  end

  test "the empty state follows the scoped list, not the unscoped one" do
    put_watch(%{})

    {:ok, _view, html} = live(conn(), "/watches?scope=acme")

    refute html =~ "site is back"
    assert html =~ "No watches."
  end
end
