defmodule PepeWeb.AgentsLivePickersTest do
  @moduledoc """
  The agent editor's closed-set fields, which used to be free-text boxes the operator had
  to know the encoding of: auto-approve (tool names, or the literal `*`), can-message
  (agent names) and admin scope (four modes crammed into one string, where `non` for
  `none` silently became a one-name allow list instead of an error).
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_pickers_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant", tools: ["bash", "read_file"]})
    Config.put_agent(%Agent{name: "helper"})
    Config.put_agent(%Agent{name: "researcher"})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}
  defp open_edit(view), do: render_click(view, "agent_edit", %{"name" => "assistant"})
  defp submit(view), do: view |> form("#agent-form", %{"agent" => %{"name" => "assistant"}}) |> render_submit()

  test "auto-approve renders a card per checked tool, and the * toggle" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ ~s(name="auto_approve[]" value="bash")
    assert html =~ ~s(name="auto_approve[]" value="read_file")
    refute html =~ ~s(name="auto_approve[]" value="web_search")
    assert html =~ ~s(name="auto_approve_all")
    refute html =~ ~s(name="auto_approve" )
  end

  test "checking an auto-approve card persists that tool" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "auto_approve" => ["bash"]})
    |> render_submit()

    assert Config.get_agent("assistant").auto_approve == ["bash"]
  end

  test "the never-ask toggle persists as *, and round-trips back checked" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "auto_approve_all" => "true"})
    |> render_submit()

    assert Config.get_agent("assistant").auto_approve == ["*"]

    html = open_edit(view)
    assert Regex.run(~r/name="auto_approve_all"[^>]*checked/, html)
    refute html =~ ~s(name="auto_approve[]")
  end

  test "unchecking a tool drops it from the auto-approve grid live" do
    Config.put_agent(%Agent{name: "assistant", tools: ["bash", "read_file"], auto_approve: ["bash"]})
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    html = render_change(view, "agent_change", %{"agent" => %{"name" => "assistant"}, "tools" => ["read_file"]})
    refute html =~ ~s(name="auto_approve[]" value="bash")
    assert html =~ ~s(name="auto_approve[]" value="read_file")
  end

  test "can_message is a chip picker over real agent names, and persists" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    refute html =~ ~s(name="can_message")
    assert html =~ ~s(name="agent_message_candidate")
    assert html =~ ~s(<option value="default/helper")
    # never offers the agent itself
    refute Regex.run(~r/name="agent_message_candidate".*?<option value="default\/assistant".*?<\/select>/s, html)

    render_change(view, "agent_message_add", %{"agent_message_candidate" => "default/helper"})
    render_change(view, "agent_message_add", %{"agent_message_candidate" => "default/researcher"})
    submit(view)

    assert Config.get_agent("assistant").can_message == ["default/helper", "default/researcher"]

    open_edit(view)
    html = render_click(view, "agent_message_remove", %{"name" => "default/helper"})
    assert html =~ "researcher"
    submit(view)
    assert Config.get_agent("assistant").can_message == ["default/researcher"]
  end

  test "can_manage: each mode round-trips through the select" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    for {mode, expected} <- [{"none", []}, {"all", ["*"]}, {"self", nil}] do
      view
      |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "can_manage_mode" => mode})
      |> render_submit()

      assert Config.get_agent("assistant").can_manage == expected, "mode #{mode}"
      open_edit(view)
    end
  end

  test "can_manage: specific agents shows the picker only in list mode and persists the names" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)
    refute html =~ ~s(name="agent_manage_candidate")

    html = render_change(view, "agent_change", %{"agent" => %{"name" => "assistant"}, "can_manage_mode" => "list"})
    assert html =~ ~s(name="agent_manage_candidate")

    render_change(view, "agent_manage_add", %{"agent_manage_candidate" => "default/helper"})

    view
    |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "can_manage_mode" => "list"})
    |> render_submit()

    assert Config.get_agent("assistant").can_manage == ["default/helper"]

    # reopening lands back on "Specific agents" with the chip present
    html = open_edit(view)
    assert html =~ ~s(<option value="list" selected)
    assert html =~ ~s(name="agent_manage_candidate")
  end

  test "slots are labelled in words, not by their raw key" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ "Reasoning loop"
    assert html =~ "Memory search"
  end

  test "the persona section is open even when a save fails validation" do
    {:ok, view, _html} = live(conn(), "/agents")
    render_click(view, "agent_new", %{})

    html = render_submit(view, "agent_save", %{"agent" => %{"name" => ""}, "system_prompt" => "kept"})

    assert html =~ "Please fix the errors below."
    assert html =~ "can&#39;t be blank"
    assert Regex.run(~r/<details open[^>]*>\s*<summary[^>]*>\s*Persona/s, html)
    assert html =~ "kept"
  end

  test "explanation paragraphs are not inside the checkbox label" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    label = Regex.run(~r/<label[^>]*>\s*<input type="checkbox" name="trust_untrusted_content".*?<\/label>/s, html)
    assert label, "expected the trust_untrusted_content label"
    refute List.first(label) =~ "<p"
  end
end
