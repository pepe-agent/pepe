defmodule Pepe.ApiScopeTest do
  @moduledoc """
  The tenancy boundary shared by the HTTP API and the WebSocket channel. A regression here leaks
  one project's agent to another's token, so its branches are pinned directly rather than only
  exercised in passing by the transport tests.
  """
  use ExUnit.Case, async: false

  alias Pepe.ApiScope
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_scope_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.add_project("acme")
    Config.add_project("globex")
    Config.put_model(%Model{name: "gpt", base_url: "https://x/v1", api_key: "k", model: "m"})
    Config.put_agent(%Agent{name: "assistant", system_prompt: "root", tools: []})
    Config.put_agent(%Agent{name: "acme/sales", system_prompt: "acme", tools: []})
    Config.put_agent(%Agent{name: "globex/bot", system_prompt: "globex", tools: []})
    Config.set_default_agent("assistant")
    :ok
  end

  describe "open (unrestricted) scope is lenient" do
    test "empty name yields the default agent" do
      assert %Agent{name: "default/assistant"} = ApiScope.authorize_agent("", :unrestricted)
    end

    test "a known agent resolves to itself" do
      assert %Agent{name: "default/assistant"} = ApiScope.authorize_agent("assistant", :unrestricted)
    end

    test "a bare model connection name resolves to nil (for model pass-through)" do
      assert ApiScope.authorize_agent("gpt", :unrestricted) == nil
    end

    test "an unknown name falls back to the default agent" do
      assert %Agent{name: "default/assistant"} = ApiScope.authorize_agent("nope", :unrestricted)
    end
  end

  describe "an agent-locked token is strict" do
    test "always returns its own agent, ignoring the requested name" do
      scope = %{project: "acme", agent: "acme/sales"}
      assert %Agent{name: "acme/sales"} = ApiScope.authorize_agent("assistant", scope)
      assert %Agent{name: "acme/sales"} = ApiScope.authorize_agent("globex/bot", scope)
    end
  end

  describe "a project token sees only its own project" do
    test "a bare name qualifies into the project" do
      assert %Agent{name: "acme/sales"} = ApiScope.authorize_agent("sales", %{project: "acme", agent: nil})
    end

    test "another project's agent is out of scope (nil), never leaked" do
      assert ApiScope.authorize_agent("globex/bot", %{project: "acme", agent: nil}) == nil
      assert ApiScope.authorize_agent("sales", %{project: "globex", agent: nil}) == nil
    end

    test "visible_agents is scoped to the project, and only that project" do
      names = ApiScope.visible_agents(%{project: "acme", agent: nil}) |> Enum.map(& &1.name)
      assert names == ["acme/sales"]
    end
  end

  describe "root_or_open? (may use a bare model connection)" do
    test "only the open scope and the root project/agent-nil scope" do
      assert ApiScope.root_or_open?(:unrestricted)
      assert ApiScope.root_or_open?(%{project: nil, agent: nil})
      refute ApiScope.root_or_open?(%{project: "acme", agent: nil})
      refute ApiScope.root_or_open?(%{project: nil, agent: "assistant"})
    end
  end
end
