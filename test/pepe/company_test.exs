defmodule Pepe.CompanyTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Company
  alias Pepe.Config
  alias Pepe.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_co_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  describe "handle parsing" do
    test "root handles have no company; company handles split on /" do
      assert Company.of("vendas") == nil
      assert Company.name_of("vendas") == "vendas"

      assert Company.of("acme/vendas") == "acme"
      assert Company.name_of("acme/vendas") == "vendas"

      assert Company.handle(nil, "vendas") == "vendas"
      assert Company.handle("acme", "vendas") == "acme/vendas"
    end

    test "same_scope? separates companies and root" do
      assert Company.same_scope?("acme/a", "acme/b")
      assert Company.same_scope?("x", "y")
      refute Company.same_scope?("acme/a", "globex/a")
      refute Company.same_scope?("acme/a", "a")
    end

    test "qualify resolves a bare target into the sender's company" do
      assert Company.qualify("vendas", "acme/suporte") == "acme/vendas"
      assert Company.qualify("globex/vendas", "acme/suporte") == "globex/vendas"
      assert Company.qualify("vendas", "suporte") == "vendas"
    end

    test "valid_name? rejects separators and punctuation" do
      assert Company.valid_name?("acme")
      assert Company.valid_name?("acme-2_x")
      refute Company.valid_name?("acme/x")
      refute Company.valid_name?("acme corp")
      refute Company.valid_name?("")
    end
  end

  describe "company CRUD" do
    test "add/list/exists/delete" do
      assert Config.companies() == []
      assert :ok = Config.add_company("acme", %{"description" => "Acme Inc"})
      assert Config.company_exists?("acme")
      assert Config.companies() == ["acme"]
      assert Config.get_company("acme")["description"] == "Acme Inc"

      assert :ok = Config.delete_company("acme")
      refute Config.company_exists?("acme")
    end

    test "rejects invalid and duplicate names" do
      assert {:error, :invalid_name} = Config.add_company("bad/name")
      assert :ok = Config.add_company("acme")
      assert {:error, :already_exists} = Config.add_company("acme")
    end

    test "delete refuses a non-empty company unless forced" do
      Config.add_company("acme")
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "x"})

      assert {:error, {:not_empty, 1}} = Config.delete_company("acme")
      assert Config.get_agent("acme/vendas")

      assert :ok = Config.delete_company("acme", force: true)
      refute Config.company_exists?("acme")
      assert Config.get_agent("acme/vendas") == nil
    end
  end

  describe "scoped agent listing" do
    test "agents_in isolates root from companies and companies from each other" do
      Config.add_company("acme")
      Config.add_company("globex")
      Config.put_agent(%Agent{name: "assistant", system_prompt: "root"})
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      Config.put_agent(%Agent{name: "globex/vendas", system_prompt: "g"})

      assert Enum.map(Config.agents_in(nil), & &1.name) == ["assistant"]
      assert Enum.map(Config.agents_in("acme"), & &1.name) == ["acme/vendas"]
      assert Enum.map(Config.agents_in("globex"), & &1.name) == ["globex/vendas"]
    end

    test "same bare name in two companies are independent agents" do
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      Config.put_agent(%Agent{name: "globex/vendas", system_prompt: "g"})

      assert Config.get_agent("acme/vendas").system_prompt == "a"
      assert Config.get_agent("globex/vendas").system_prompt == "g"
    end

    test "a company agent never becomes the global default" do
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      assert Config.default_agent_name() == nil

      Config.put_agent(%Agent{name: "assistant", system_prompt: "root"})
      assert Config.default_agent_name() == "assistant"
    end
  end

  describe "workspace isolation" do
    test "root and company agents get separate workspace directories" do
      assert Workspace.dir("vendas") == Path.join([Config.home(), "agents", "vendas"])

      assert Workspace.dir("acme/vendas") ==
               Path.join([Config.home(), "companies", "acme", "agents", "vendas"])

      # identical bare names in different companies never collide
      refute Workspace.dir("acme/vendas") == Workspace.dir("globex/vendas")
    end

    test "shared/ resolves per company, not globally" do
      root_shared = Workspace.resolve("shared/notes.md", "vendas")
      acme_shared = Workspace.resolve("shared/notes.md", "acme/vendas")

      assert root_shared == Path.join([Config.home(), "shared", "notes.md"])

      assert acme_shared ==
               Path.join([Config.home(), "companies", "acme", "shared", "notes.md"])

      refute root_shared == acme_shared
    end
  end

  describe "model scoping" do
    test "company agent resolves its own model, then root, then default" do
      Config.add_company("acme")
      Config.put_model(%Config.Model{name: "shared-llm", base_url: "u", api_key: "k", model: "m"})
      Config.set_default_model("shared-llm")

      # inherits the root default when it pins nothing
      inherit = %Agent{name: "acme/vendas", model: nil}
      assert Config.model_for_agent(inherit).name == "shared-llm"

      # a company-scoped model with the same bare ref wins over root
      Config.put_model(%Config.Model{
        name: "acme/priv",
        base_url: "u2",
        api_key: "k2",
        model: "m2"
      })

      pinned = %Agent{name: "acme/vendas", model: "priv"}
      assert Config.model_for_agent(pinned).name == "acme/priv"
    end
  end
end
