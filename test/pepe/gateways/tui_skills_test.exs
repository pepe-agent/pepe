defmodule Pepe.Gateways.TUISkillsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Agent.Session
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.Gateways.TUI
  alias Pepe.Skills.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tui_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.MockLLM, port: 0, scheme: :http)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "console", model: "mock", tools: ["skill"]})

    File.write!(Path.join([home, "skills", "ship-it.md"]), "---\nname: ship-it\ndescription: Use when shipping.\n---\n\nSteps.\n")

    on_exit(fn ->
      Pepe.Test.Sessions.stop_all!()
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home, key: "tui:skills:#{System.unique_integer([:positive])}"}
  end

  defp run(key, lines) do
    capture_io([input: Enum.join(lines, "\n") <> "\n"], fn -> TUI.start("console", key) end)
  end

  defp user_turns(key), do: key |> Session.history() |> Enum.filter(&(&1["role"] == "user")) |> Enum.map(& &1["content"])

  test "/skills lists what the agent is offered, with what a skill still needs", %{home: home, key: key} do
    File.write!(
      Path.join([home, "skills", "needs-key.md"]),
      "---\nname: needs-key\ndescription: Use when a key is needed.\nrequired_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n---\n\nSteps.\n"
    )

    out = run(key, ["/skills"])

    assert out =~ "Available skills"
    assert out =~ "ship-it"
    assert out =~ "needs-key"
    assert out =~ "needs PEPE_TEST_SURELY_UNSET_KEY"
  end

  test "a skill is its own command and hands the agent the instruction", %{key: key} do
    run(key, ["/ship-it to staging"])

    assert ~s(Carry out the "ship-it" skill now.\n\nInput: to staging) in user_turns(key)
  end

  test "/skill NAME runs it too, by the underscore spelling as well", %{key: key} do
    run(key, ["/skill ship_it now"])

    assert ~s(Carry out the "ship-it" skill now.\n\nInput: now) in user_turns(key)
  end

  test "an unknown skill or command says so and runs nothing", %{key: key} do
    out = run(key, ["/skill ghost", "/ghost"])

    assert out =~ "Unknown skill: ghost"
    assert out =~ "Unknown command: /ghost"
    assert user_turns(key) == []
  end

  test "a skill disabled on the console is not a command", %{key: key} do
    Settings.disable("ship-it", "tui")

    out = run(key, ["/skills", "/ship-it"])

    refute out =~ "- ship-it"
    assert out =~ "Unknown command: /ship-it"
    assert user_turns(key) == []
  end

  test "an agent without the skill tool is offered none", %{key: key} do
    Config.put_agent(%Agent{name: "console", model: "mock", tools: ["bash"]})

    out = run(key, ["/skills", "/ship-it"])

    assert out =~ "No skills are available yet."
    assert out =~ "Unknown command: /ship-it"
  end
end
