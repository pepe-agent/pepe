defmodule Pepe.RenameModelTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Cron
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_rename_model_#{System.unique_integer([:positive])}")
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

  test "rejects unknown or duplicate names, no-ops on same name" do
    Config.put_model(%Model{name: "openrouter", model: "gpt-4o"})
    Config.put_model(%Model{name: "openrouter-2", model: "gpt-4o"})

    assert Config.rename_model("nope", "x") == {:error, :not_found}
    assert Config.rename_model("openrouter", "openrouter-2") == {:error, :already_exists}
    assert Config.rename_model("openrouter", "openrouter") == :ok
  end

  test "renaming is a plain field update - every id-based reference survives untouched" do
    Config.put_model(%Model{name: "openrouter", model: "gpt-4o", fallbacks: []})
    Config.put_model(%Model{name: "backup", model: "gpt-4o", fallbacks: ["openrouter"]})
    Config.set_default_model("openrouter")
    Config.add_project("acme", %{})
    Config.set_default_model_for("acme", "openrouter")

    Config.put_agent(%Agent{name: "assistant", model: "openrouter"})
    Config.put_cron(%Cron{id: "c1", agent: "assistant", model: "openrouter", prompt: "hi", schedule: "0 8 * * *"})
    Config.put_hook_settings("llm_redact", %{"model" => "openrouter"})

    id_before = Config.model_id_for("openrouter")

    assert Config.rename_model("openrouter", "OR-chave2") == :ok

    # same stable id, new display name
    assert Config.get_model("openrouter") == nil
    assert Config.get_model("OR-chave2").id == id_before
    assert Config.get_model("OR-chave2").model == "gpt-4o"

    # id-based references need no rewriting - the on-disk pointer is unchanged,
    # only what it resolves to now displays the new name
    assert Config.default_model_name() == "OR-chave2"
    assert Config.get_project("acme")["default_model"] == id_before
    assert Config.default_model_for("acme").name == "OR-chave2"
    assert Config.get_agent("assistant").model == "OR-chave2"
    assert Config.get_cron("c1").model == "OR-chave2"

    # the two fields that stay name-based still get rewritten
    assert Config.hook_settings("llm_redact")["model"] == "OR-chave2"
    assert Config.get_model("backup").fallbacks == ["OR-chave2"]
  end

  test "rejects renaming across a project boundary" do
    Config.add_project("acme", %{})
    Config.put_model(%Model{name: "acme/openrouter", model: "gpt-4o"})

    assert Config.rename_model("acme/openrouter", "openrouter") == {:error, :scope_mismatch}
    assert Config.rename_model("acme/openrouter", "acme/OR-chave2") == :ok
  end

  test "does not touch historical usage records" do
    Config.put_model(%Model{name: "openrouter", model: "gpt-4o"})
    Pepe.Usage.record("assistant", "openrouter", %{"prompt_tokens" => 100, "completion_tokens" => 0})

    assert Config.rename_model("openrouter", "OR-chave2") == :ok

    keys = Pepe.Usage.summary("default", :day).by_model |> Enum.map(& &1.key)
    assert "openrouter" in keys
    refute "OR-chave2" in keys
  end
end
