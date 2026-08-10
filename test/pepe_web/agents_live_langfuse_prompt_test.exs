defmodule PepeWeb.AgentsLiveLangfusePromptTest do
  @moduledoc """
  The agent editor's "Langfuse-managed prompt" field - an agent opts into having its
  persona come from Langfuse instead of the local one by naming a prompt here.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_lf_prompt_#{System.unique_integer([:positive])}")
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
  defp open_edit(view), do: render_click(view, "agent_edit", %{"name" => "assistant"})

  test "the field is present, empty, in the edit form" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = open_edit(view)

    assert html =~ ~s(name="langfuse_prompt")
  end

  test "setting it persists to config and shows on reopen" do
    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "langfuse_prompt" => "support-persona"})
    |> render_submit()

    assert Config.get_agent("assistant").langfuse_prompt == "support-persona"

    html = open_edit(view)
    assert html =~ ~s(value="support-persona")
  end

  test "blank clears it back to nil (opting back out)" do
    Config.put_agent(%{Config.get_agent("assistant") | langfuse_prompt: "old-name"})

    {:ok, view, _html} = live(conn(), "/agents")
    open_edit(view)

    view
    |> form("#agent-form", %{"agent" => %{"name" => "assistant"}, "langfuse_prompt" => ""})
    |> render_submit()

    assert Config.get_agent("assistant").langfuse_prompt == nil
  end

  test "a new agent's blank form doesn't crash on this field" do
    {:ok, view, _html} = live(conn(), "/agents")
    html = render_click(view, "agent_new", %{})

    assert html =~ ~s(name="langfuse_prompt")
  end
end
