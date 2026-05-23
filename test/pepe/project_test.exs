defmodule Pepe.ProjectTest do
  use ExUnit.Case, async: false

  alias Pepe.Agent.Workspace
  alias Pepe.Project
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
    test "root handles have no project; project handles split on /" do
      assert Project.of("vendas") == nil
      assert Project.name_of("vendas") == "vendas"

      assert Project.of("acme/vendas") == "acme"
      assert Project.name_of("acme/vendas") == "vendas"

      assert Project.handle(nil, "vendas") == "vendas"
      assert Project.handle("acme", "vendas") == "acme/vendas"
    end

    test "same_scope? separates projects and root" do
      assert Project.same_scope?("acme/a", "acme/b")
      assert Project.same_scope?("x", "y")
      refute Project.same_scope?("acme/a", "globex/a")
      refute Project.same_scope?("acme/a", "a")
    end

    test "qualify resolves a bare target into the sender's project" do
      assert Project.qualify("vendas", "acme/suporte") == "acme/vendas"
      assert Project.qualify("globex/vendas", "acme/suporte") == "globex/vendas"
      assert Project.qualify("vendas", "suporte") == "vendas"
    end

    test "valid_name? rejects separators and punctuation" do
      assert Project.valid_name?("acme")
      assert Project.valid_name?("acme-2_x")
      refute Project.valid_name?("acme/x")
      refute Project.valid_name?("acme corp")
      refute Project.valid_name?("")
      # \A..\z, not ^..$: a trailing newline must not slip past (would weaken the traversal guard).
      refute Project.valid_name?("acme\n")
      refute Project.valid_name?("\nacme")
    end
  end

  describe "project CRUD" do
    test "add/list/exists/delete" do
      assert Config.project_slugs() == []
      assert :ok = Config.add_project("acme", %{"description" => "Acme Inc"})
      assert Config.project_exists?("acme")
      assert Config.project_slugs() == ["acme"]
      assert Config.get_project("acme")["description"] == "Acme Inc"

      assert :ok = Config.delete_project("acme")
      refute Config.project_exists?("acme")
    end

    test "rejects invalid and duplicate names" do
      assert {:error, :invalid_slug} = Config.add_project("bad/name")
      assert :ok = Config.add_project("acme")
      assert {:error, :already_exists} = Config.add_project("acme")
    end

    test "delete refuses a non-empty project unless forced" do
      Config.add_project("acme")
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "x"})

      assert {:error, {:not_empty, 1}} = Config.delete_project("acme")
      assert Config.get_agent("acme/vendas")

      assert :ok = Config.delete_project("acme", force: true)
      refute Config.project_exists?("acme")
      assert Config.get_agent("acme/vendas") == nil
      # Actually gone, not orphaned: a `force` delete must remove the agent entry, not leave it to
      # resurface reparented under the default project on the next listing.
      assert Config.agents() == []
    end

    test "delete removes only the deleted project's agents, sparing others" do
      Config.add_project("acme")
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "x"})
      Config.put_agent(%Agent{name: "keeper", system_prompt: "y"})

      assert :ok = Config.delete_project("acme", force: true)
      assert Enum.map(Config.agents(), & &1.name) == ["default/keeper"]
    end
  end

  describe "name validation (path-traversal defense)" do
    test "put_agent refuses a handle whose segments aren't plain labels, and stores nothing" do
      assert {:error, :invalid_name} = Config.put_agent(%Agent{name: "acme/../../../pwn", system_prompt: "x"})
      assert {:error, :invalid_name} = Config.put_agent(%Agent{name: "../etc/passwd", system_prompt: "x"})
      assert Config.agents() == []
    end

    test "Workspace.dir refuses a traversal handle as a last-line backstop" do
      assert_raise ArgumentError, fn -> Pepe.Agent.Workspace.dir("acme/../../etc") end
      assert_raise ArgumentError, fn -> Pepe.Agent.Workspace.dir("default/..") end
    end
  end

  describe "rename_agent" do
    test "refuses a collision with another agent in the same project, sparing both" do
      Config.add_project("acme")
      Config.put_agent(%Agent{name: "acme/a", system_prompt: "x"})
      Config.put_agent(%Agent{name: "acme/b", system_prompt: "y"})

      assert {:error, :already_exists} = Config.rename_agent("acme/a", "acme/b")
      assert Config.get_agent("acme/a").system_prompt == "x"
      assert Config.get_agent("acme/b").system_prompt == "y"
    end

    test "refuses an invalid new name" do
      Config.put_agent(%Agent{name: "helper", system_prompt: "x"})
      assert {:error, :invalid_name} = Config.rename_agent("helper", "../../x")
    end

    test "relabels the agent and its id-based references follow the rename" do
      Config.put_agent(%Agent{name: "boss", system_prompt: "b"})
      Config.put_agent(%Agent{name: "helper", system_prompt: "h"})
      Config.allow_message("boss", "helper")

      assert :ok = Config.rename_agent("helper", "assistant")
      assert Config.get_agent("assistant").system_prompt == "h"
      assert Config.get_agent("helper") == nil
      # can_message is stored by id, so the route now resolves to the new handle - not dangling.
      assert Config.get_agent("boss").can_message == ["default/assistant"]
    end
  end

  describe "scoped agent listing" do
    test "agents_in isolates root from projects and projects from each other" do
      Config.add_project("acme")
      Config.add_project("globex")
      Config.put_agent(%Agent{name: "assistant", system_prompt: "root"})
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      Config.put_agent(%Agent{name: "globex/vendas", system_prompt: "g"})

      assert Enum.map(Config.agents_in(nil), & &1.name) == ["default/assistant"]
      assert Enum.map(Config.agents_in("acme"), & &1.name) == ["acme/vendas"]
      assert Enum.map(Config.agents_in("globex"), & &1.name) == ["globex/vendas"]
    end

    test "same bare name in two projects are independent agents" do
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      Config.put_agent(%Agent{name: "globex/vendas", system_prompt: "g"})

      assert Config.get_agent("acme/vendas").system_prompt == "a"
      assert Config.get_agent("globex/vendas").system_prompt == "g"
    end

    test "a project agent never becomes the global default" do
      Config.put_agent(%Agent{name: "acme/vendas", system_prompt: "a"})
      assert Config.default_agent_name() == nil

      Config.put_agent(%Agent{name: "assistant", system_prompt: "root"})
      assert Config.default_agent_name() == "default/assistant"
    end
  end

  describe "workspace isolation" do
    test "root and project agents get separate workspace directories" do
      assert Workspace.dir("vendas") == Path.join([Config.home(), "projects", "default", "agents", "vendas"])

      assert Workspace.dir("acme/vendas") ==
               Path.join([Config.home(), "projects", "acme", "agents", "vendas"])

      # identical bare names in different projects never collide
      refute Workspace.dir("acme/vendas") == Workspace.dir("globex/vendas")
    end

    test "shared/ resolves per project, not globally" do
      root_shared = Workspace.resolve("shared/notes.md", "vendas")
      acme_shared = Workspace.resolve("shared/notes.md", "acme/vendas")

      assert root_shared == Path.join([Config.home(), "projects", "default", "shared", "notes.md"])

      assert acme_shared ==
               Path.join([Config.home(), "projects", "acme", "shared", "notes.md"])

      refute root_shared == acme_shared
    end
  end

  describe "model scoping" do
    test "project agent resolves its own model, then root, then default" do
      Config.add_project("acme")
      Config.put_model(%Config.Model{name: "shared-llm", base_url: "u", api_key: "k", model: "m"})
      Config.set_default_model("shared-llm")

      # inherits the root default when it pins nothing
      inherit = %Agent{name: "acme/vendas", model: nil}
      assert Config.model_for_agent(inherit).name == "shared-llm"

      # a project-scoped model with the same bare ref wins over root
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
