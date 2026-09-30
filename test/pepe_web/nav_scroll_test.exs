defmodule PepeWeb.NavScrollTest do
  @moduledoc """
  The sidebar menu is rebuilt on every navigation (each item is a different LiveView), which
  used to send its scroll back to the top. A hook keeps the position; the page's own item is
  marked `aria-current` so the hook has something to bring into view.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_navscroll_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "the nav carries the scroll-keeping hook and marks only the current page" do
    {:ok, view, _html} = live(%{build_conn() | host: "localhost"}, "/agents")

    assert has_element?(view, "nav#pepe-nav[phx-hook$=NavScroll]")
    assert has_element?(view, ~s(nav#pepe-nav a[href="/agents"][aria-current=page]))
    refute has_element?(view, ~s(nav#pepe-nav a[href="/models"][aria-current]))
  end
end
