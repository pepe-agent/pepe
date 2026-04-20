defmodule PepeWeb.AgentsLiveMessageLimitTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agentslimit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_model(%Model{name: "primary", base_url: "https://x", model: "gpt-a"})
    Config.put_agent(%Agent{name: "assistant", model: "primary"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open_edit(view), do: render_click(view, "agent_edit", %{"name" => "assistant"})

  test "the edit form shows an unchecked exemption box by default" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ ~s(name="exempt_message_limit")
    refute Regex.run(~r/name="exempt_message_limit"[^>]*checked/, html)
  end

  test "saving without checking the box leaves the agent not exempt" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    refute Config.get_agent("assistant").exempt_message_limit
  end

  test "saving with the box checked persists the exemption" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{
      "agent" => %{"name" => "assistant"},
      "exempt_message_limit" => "true"
    })
    |> render_submit()

    assert Config.get_agent("assistant").exempt_message_limit
  end

  test "an already-exempt agent shows the box checked when reopened, and stays exempt if resaved as-is" do
    Config.put_agent(%Agent{name: "assistant", model: "primary", exempt_message_limit: true})

    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)
    assert Regex.run(~r/name="exempt_message_limit"[^>]*checked/, html)

    view
    |> form("form[phx-submit=agent_save]", %{
      "agent" => %{"name" => "assistant"},
      "exempt_message_limit" => "true"
    })
    |> render_submit()

    assert Config.get_agent("assistant").exempt_message_limit
  end
end
