defmodule PepeWeb.AgentsLivePromptTest do
  @moduledoc """
  The "Assembled prompt" section on an agent's edit form - what the model actually sees,
  not just the persona field the form itself edits. Same assembly the CLI's
  `mix pepe agent prompt` and every real conversation with the agent already go through.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_agentsui_prompt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Agent{name: "assistant", system_prompt: "You are a terse assistant."})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  test "editing an existing agent shows the assembled prompt, not just the persona seed" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = render_click(view, "agent_edit", %{"name" => "assistant"})

    assert html =~ "Assembled prompt"
    assert html =~ "You are a terse assistant."
    # Framework scaffolding this test never wrote itself - proof it is the assembled
    # prompt, not the raw persona field rendered twice.
    assert html =~ "Current time"
  end

  test "a brand-new, not-yet-saved agent has no assembled prompt to show yet" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = render_click(view, "agent_new", %{})

    refute html =~ "Assembled prompt"
  end
end
