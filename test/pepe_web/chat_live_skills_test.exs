defmodule PepeWeb.ChatLiveSkillsTest do
  @moduledoc """
  Installed skills as slash commands in the dashboard chat: offered in the command menu the
  same way the skills index offers them to the agent, and run as an ordinary turn.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Skills.Settings

  @endpoint PepeWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_chatui_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "skilled", model: "mock", tools: ["skill"]})
    Config.put_agent(%Agent{name: "bare", model: "mock", tools: ["bash"]})

    File.write!(Path.join([home, "skills", "ship-it.md"]), "---\nname: ship-it\ndescription: Use when shipping.\n---\n\nSteps.\n")

    on_exit(fn ->
      Pepe.Test.Sessions.stop_all!()
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp conn, do: %{build_conn() | host: "localhost"}

  defp open(agent) do
    key = "web:skills-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Pepe.Agent.SessionSupervisor.ensure(key, agent)
    on_exit(fn -> Pepe.Agent.SessionSupervisor.terminate(key) end)
    {:ok, view, _html} = live(conn(), "/chat?chat=#{key}")
    {view, key}
  end

  defp type(view, text), do: view |> form("#chat-compose", %{"text" => text}) |> render_change()

  test "typing a slash offers the installed skills beside the built-in commands" do
    {view, _key} = open("skilled")

    html = type(view, "/")
    assert html =~ "/ship-it"
    assert html =~ "Use when shipping."
    assert html =~ "/rewind"

    html = type(view, "/sh")
    assert html =~ "/ship-it"
    refute html =~ "/rewind"
  end

  test "a skill is run by its own command, as a turn carrying the input" do
    {view, _key} = open("skilled")

    view |> form("#chat-compose", %{"text" => "/ship-it to staging"}) |> render_submit()

    html = render(view)
    assert html =~ "Carry out the"
    assert html =~ "ship-it"
    assert html =~ "Input: to staging"
  end

  test "/skill NAME runs it as well, and an unknown one is refused" do
    {view, _key} = open("skilled")

    html = view |> form("#chat-compose", %{"text" => "/skill ghost"}) |> render_submit()
    assert html =~ "Unknown skill: ghost"

    view |> form("#chat-compose", %{"text" => "/skill ship_it now"}) |> render_submit()
    assert render(view) =~ "Input: now"
  end

  test "an unknown command that is not a skill is still refused" do
    {view, _key} = open("skilled")

    html = view |> form("#chat-compose", %{"text" => "/ghost"}) |> render_submit()

    assert html =~ "Unknown command /ghost"
  end

  test "a skill disabled on this channel is neither offered nor runnable" do
    Settings.disable("ship-it", "web")
    {view, _key} = open("skilled")

    refute type(view, "/sh") =~ "/ship-it"

    html = view |> form("#chat-compose", %{"text" => "/ship-it"}) |> render_submit()
    assert html =~ "Unknown command /ship-it"
  end

  test "an agent without the skill tool is offered no skill commands" do
    {view, _key} = open("bare")

    refute type(view, "/sh") =~ "/ship-it"
  end
end
