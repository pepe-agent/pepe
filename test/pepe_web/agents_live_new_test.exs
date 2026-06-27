defmodule PepeWeb.AgentsLiveNewTest do
  @moduledoc """
  The "+ New agent" button opens a blank form. Its assign must carry every key the template
  dot-accesses (`max_iterations`, `tool_progress`, ...) or the render raises `KeyError` and the
  whole page crashes - a broken button that no fallback test would have caught.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agentsnew_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "opening the new-agent form renders without crashing" do
    {:ok, view, _html} = live(conn(), "/agents")

    html = render_click(view, "agent_new", %{})

    # The form fields that dot-access the blank assign are present and empty.
    assert html =~ ~s(name="max_iterations")
    assert html =~ ~s(name="tool_progress")
  end
end
