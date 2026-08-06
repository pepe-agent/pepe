defmodule Mix.Tasks.PepePolicyCliTest do
  @moduledoc """
  `mix pepe policy scope` sets which agents/projects a `Pepe.Permissions.Policy` plugin
  applies to - the operator's call, never the agent's own opt-out. `policy list` shows every
  installed policy and its current scope.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_policycli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "plugins"))
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "list reports no policies when none are installed" do
    assert pepe(["policy", "list"]) =~ "no policy plugins installed"
  end

  test "list shows an installed policy as unscoped by default", %{home: home} do
    write_policy(home, "cli_policy")
    assert pepe(["policy", "list"]) =~ "every agent"
  end

  test "scope --agents sets a scope; list then shows it", %{home: home} do
    write_policy(home, "cli_policy")

    assert pepe(["policy", "scope", "cli_policy", "--agents", "support,onboarding"]) =~ "scoped to"
    assert Config.policy_scope("cli_policy") == %{"agents" => ["support", "onboarding"]}
    assert pepe(["policy", "list"]) =~ "support"
  end

  test "scope --projects sets a project scope" do
    assert pepe(["policy", "scope", "cli_policy", "--projects", "acme,globex"]) =~ "scoped to"
    assert Config.policy_scope("cli_policy") == %{"projects" => ["acme", "globex"]}
  end

  test "scope with both --agents and --projects sets both" do
    pepe(["policy", "scope", "cli_policy", "--agents", "support", "--projects", "acme"])
    assert Config.policy_scope("cli_policy") == %{"agents" => ["support"], "projects" => ["acme"]}
  end

  test "scope --clear removes a scope, back to applying everywhere" do
    Config.put_policy_scope("cli_policy", %{"agents" => ["support"]})
    assert pepe(["policy", "scope", "cli_policy", "--clear"]) =~ "cleared"
    assert Config.policy_scope("cli_policy") == nil
  end

  test "scope with no flags at all is refused, not silently a no-op" do
    assert pepe_err(["policy", "scope", "cli_policy"]) =~ "usage:"
    assert Config.policy_scope("cli_policy") == nil
  end

  defp write_policy(home, name) do
    File.write!(Path.join([home, "plugins", "#{name}.exs"]), """
    defmodule PepePolicyCliTest.#{Macro.camelize(name)} do
      @behaviour Pepe.Permissions.Policy
      def name, do: "#{name}"
      def check(_name, _args, _ctx), do: :allow
    end
    """)
  end
end
