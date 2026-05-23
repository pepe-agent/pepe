defmodule Pepe.RenameProjectTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Config
  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rename_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp seed do
    Config.add_project("acme", %{"description" => "Acme Inc", "markup" => 1.5})

    Config.put_agent(%Agent{
      name: "acme/sales",
      can_message: ["acme/support"],
      can_manage: ["acme/support"]
    })

    Config.put_agent(%Agent{name: "acme/support"})
    Config.put_model(%Pepe.Config.Model{name: "acme/llm", model: "gpt-4o"})
  end

  test "rejects bad, unknown or duplicate names" do
    seed()
    Config.add_project("globex")

    assert Config.rename_project("acme", "bad name") == {:error, :invalid_slug}
    assert Config.rename_project("nope", "x") == {:error, :not_found}
    assert Config.rename_project("acme", "globex") == {:error, :already_exists}
    assert Config.rename_project("acme", "acme") == :ok
  end

  test "re-keys the project, its agents, models and routes" do
    seed()
    assert Config.rename_project("acme", "umbrella") == :ok

    # project entry moved, meta preserved
    assert "acme" not in Config.project_slugs()
    assert "umbrella" in Config.project_slugs()
    assert Config.get_project("umbrella")["description"] == "Acme Inc"
    assert Config.project_markup("umbrella") == 1.5

    # agents re-keyed, and cross-refs inside them rewritten
    names = Enum.map(Config.agents(), & &1.name) |> Enum.sort()
    assert names == ["umbrella/sales", "umbrella/support"]

    sales = Config.get_agent("umbrella/sales")
    assert sales.can_message == ["umbrella/support"]
    assert sales.can_manage == ["umbrella/support"]

    # model re-keyed
    assert Enum.map(Config.models(), & &1.name) == ["umbrella/llm"]

    # agents_in follows the new scope
    assert Enum.map(Config.agents_in("umbrella"), & &1.name) |> Enum.sort() ==
             ["umbrella/sales", "umbrella/support"]

    assert Config.agents_in("acme") == []
  end

  test "re-binds crons, watches, bots and tokens" do
    seed()

    Config.put_cron(%Pepe.Config.Cron{
      id: "c1",
      agent: "acme/sales",
      prompt: "hi",
      schedule: "0 8 * * *"
    })

    Config.put_watch(%Pepe.Config.Watch{id: "w1", agent: "acme/support", trigger: %{}})

    Config.put_telegram_bot("sales", %{
      "name" => "sales",
      "agent" => "acme/sales",
      "bot_token" => "${T}"
    })

    assert {:ok, raw, _id} =
             Config.add_api_token(project: "acme", agent: "acme/sales", label: "x")

    assert is_binary(raw)

    assert Config.rename_project("acme", "umbrella") == :ok

    assert Config.get_cron("c1").agent == "umbrella/sales"
    assert Config.get_watch("w1").agent == "umbrella/support"
    assert Config.telegram_bot("sales")["agent"] == "umbrella/sales"

    [tok] = Config.api_tokens()
    assert tok["project"] == "umbrella"
    assert tok["agent"] == "umbrella/sales"
    # the cron prompt (free text) is untouched
    assert Config.get_cron("c1").prompt == "hi"
  end

  test "moves the workspace and usage directories on disk" do
    seed()
    # create a workspace file + a usage ledger entry under acme
    File.mkdir_p!(Workspace.dir("acme/sales"))
    File.write!(Path.join(Workspace.dir("acme/sales"), "MEMORY.md"), "remember me")

    Pepe.Usage.record("acme/sales", "acme/llm", %{
      "prompt_tokens" => 1000,
      "completion_tokens" => 0
    })

    assert Config.rename_project("acme", "umbrella") == :ok

    # old dirs gone, new dirs carry the content
    refute File.dir?(Path.join([Config.home(), "projects", "acme"]))
    assert File.read!(Path.join(Workspace.dir("umbrella/sales"), "MEMORY.md")) == "remember me"
    assert Pepe.Usage.summary("umbrella", :month).totals.total == 1000
    assert Pepe.Usage.summary("acme", :month).totals.total == 0
  end
end
