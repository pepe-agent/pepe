defmodule PepeWeb.AgentsLiveSlotsTest do
  @moduledoc """
  The agent editor's "Extension slots" section - a per-agent override for an exclusive
  extension point (`Pepe.Slots`), previously only reachable via `mix pepe agent add
  --slots` or a hand-edited config.json.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agents_slots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp conn, do: %{build_conn() | host: "localhost"}
  defp open_edit(view), do: render_click(view, "agent_edit", %{"name" => "assistant"})

  test "renders one select per known slot, all defaulting to \"Default\"" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    for slot <- Pepe.Slots.names() do
      assert html =~ ~s(name="slots[#{slot}]"),
             "expected a select for the #{slot} slot"
    end
  end

  test "an installed plugin claiming a slot appears as an option", %{home: home} do
    File.write!(Path.join([home, "plugins", "example_memory.exs"]), """
    defmodule AgentsLiveSlotsTest.ExampleMemory do
      @behaviour Pepe.Memory.Backend
      def name, do: "example_memory"
      def slot, do: "memory"
      def search(_agent, _query, _opts), do: {:ok, []}
    end
    """)

    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ ~s(<option value="example_memory")
  end

  test "saving with every slot left on \"Default\" persists an empty override", %{} do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    assert Config.get_agent("assistant").slots == %{}
  end

  test "picking a plugin for one slot persists just that override", %{home: home} do
    File.write!(Path.join([home, "plugins", "external_cli_harness.exs"]), """
    defmodule AgentsLiveSlotsTest.Harness do
      @behaviour Pepe.Agent.Harness
      def name, do: "external_cli_harness"
      def slot, do: "harness"
      def run(_agent, messages, _opts), do: {:ok, "fixed reply", messages}
    end
    """)

    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{
      "agent" => %{"name" => "assistant"},
      "slots" => %{"harness" => "external_cli_harness"}
    })
    |> render_submit()

    assert Config.get_agent("assistant").slots == %{"harness" => "external_cli_harness"}
  end

  test "picking \"Default\" again clears a previously-saved override" do
    Config.put_agent(%Agent{name: "assistant", slots: %{"harness" => "was_set"}})

    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("form[phx-submit=agent_save]", %{
      "agent" => %{"name" => "assistant"},
      "slots" => %{"harness" => ""}
    })
    |> render_submit()

    assert Config.get_agent("assistant").slots == %{}
  end

  test "a stored override for a slot whose plugin no longer resolves round-trips through an unrelated save, not erased" do
    # No plugin named "gone" is installed - the stored value has nothing in
    # Pepe.Slots.candidates("harness") to match. Before the fix, no <option> in the
    # select was `selected`, the browser (and Phoenix.LiveViewTest's own form-parsing,
    # which mirrors it) fell back to the first option ("Default"), and saving ANY other
    # field on this agent would silently submit "" for this slot and erase the override.
    Config.put_agent(%Agent{name: "assistant", slots: %{"harness" => "gone"}})

    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ ~s(<option value="gone" selected)

    # Save without touching the slots section at all - only the "agent" param is given,
    # exactly like editing the persona and saving would look from the test's perspective.
    view
    |> form("form[phx-submit=agent_save]", %{"agent" => %{"name" => "assistant"}})
    |> render_submit()

    assert Config.get_agent("assistant").slots == %{"harness" => "gone"}
  end

  test "a forged \"slots\" param naming an unknown slot is dropped, not persisted" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    # form/3 + render_submit/1 mimics a real browser, which can't submit a field that
    # isn't in the DOM - the <select> only ever emits known slot names, so there's no
    # way to build this case through it. render_submit/3 calls the event handler
    # directly, the same way a raw POST from something other than this page's own
    # rendered form (a forged request) would arrive.
    render_submit(view, "agent_save", %{
      "agent" => %{"name" => "assistant"},
      "slots" => %{"memory" => "x", "bogus_slot" => "y"}
    })

    assert Config.get_agent("assistant").slots == %{"memory" => "x"}
  end
end
