defmodule Pepe.RenameCompanyTest do
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
    Config.add_company("acme", %{"description" => "Acme Inc", "markup" => 1.5})

    Config.put_agent(%Agent{
      name: "acme/vendas",
      can_message: ["acme/suporte"],
      can_manage: ["acme/suporte"]
    })

    Config.put_agent(%Agent{name: "acme/suporte"})
    Config.put_model(%Pepe.Config.Model{name: "acme/llm", model: "gpt-4o"})
  end

  test "rejects bad, unknown or duplicate names" do
    seed()
    Config.add_company("globex")

    assert Config.rename_company("acme", "bad name") == {:error, :invalid_name}
    assert Config.rename_company("nope", "x") == {:error, :not_found}
    assert Config.rename_company("acme", "globex") == {:error, :already_exists}
    assert Config.rename_company("acme", "acme") == :ok
  end

  test "re-keys the company, its agents, models and routes" do
    seed()
    assert Config.rename_company("acme", "umbrella") == :ok

    # company entry moved, meta preserved
    assert "acme" not in Config.companies()
    assert "umbrella" in Config.companies()
    assert Config.get_company("umbrella")["description"] == "Acme Inc"
    assert Config.company_markup("umbrella") == 1.5

    # agents re-keyed, and cross-refs inside them rewritten
    names = Enum.map(Config.agents(), & &1.name) |> Enum.sort()
    assert names == ["umbrella/suporte", "umbrella/vendas"]

    vendas = Config.get_agent("umbrella/vendas")
    assert vendas.can_message == ["umbrella/suporte"]
    assert vendas.can_manage == ["umbrella/suporte"]

    # model re-keyed
    assert Enum.map(Config.models(), & &1.name) == ["umbrella/llm"]

    # agents_in follows the new scope
    assert Enum.map(Config.agents_in("umbrella"), & &1.name) |> Enum.sort() ==
             ["umbrella/suporte", "umbrella/vendas"]

    assert Config.agents_in("acme") == []
  end

  test "re-binds crons, watches, bots and tokens" do
    seed()

    Config.put_cron(%Pepe.Config.Cron{
      id: "c1",
      agent: "acme/vendas",
      prompt: "hi",
      schedule: "0 8 * * *"
    })

    Config.put_watch(%Pepe.Config.Watch{id: "w1", agent: "acme/suporte", trigger: %{}})

    Config.put_telegram_bot("sales", %{
      "name" => "sales",
      "agent" => "acme/vendas",
      "bot_token" => "${T}"
    })

    assert {:ok, raw, _id} =
             Config.add_api_token(company: "acme", agent: "acme/vendas", label: "x")

    assert is_binary(raw)

    assert Config.rename_company("acme", "umbrella") == :ok

    assert Config.get_cron("c1").agent == "umbrella/vendas"
    assert Config.get_watch("w1").agent == "umbrella/suporte"
    assert Config.telegram_bot("sales")["agent"] == "umbrella/vendas"

    [tok] = Config.api_tokens()
    assert tok["company"] == "umbrella"
    assert tok["agent"] == "umbrella/vendas"
    # the cron prompt (free text) is untouched
    assert Config.get_cron("c1").prompt == "hi"
  end

  test "moves the workspace and usage directories on disk" do
    seed()
    # create a workspace file + a usage ledger entry under acme
    File.mkdir_p!(Workspace.dir("acme/vendas"))
    File.write!(Path.join(Workspace.dir("acme/vendas"), "MEMORY.md"), "remember me")

    Pepe.Usage.record("acme/vendas", "acme/llm", %{
      "prompt_tokens" => 1000,
      "completion_tokens" => 0
    })

    assert Config.rename_company("acme", "umbrella") == :ok

    # old dirs gone, new dirs carry the content
    refute File.dir?(Path.join([Config.home(), "companies", "acme"]))
    assert File.read!(Path.join(Workspace.dir("umbrella/vendas"), "MEMORY.md")) == "remember me"
    assert Pepe.Usage.summary("umbrella", :month).totals.total == 1000
    assert Pepe.Usage.summary("acme", :month).totals.total == 0
  end
end
