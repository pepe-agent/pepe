defmodule Mix.Tasks.PepeCompanyCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp pepe(argv), do: capture_io(fn -> Mix.Tasks.Pepe.dispatch(argv) end)
  # Errors are printed to stderr, so capture that stream for failure-path assertions.
  defp pepe_err(argv), do: capture_io(:stderr, fn -> Mix.Tasks.Pepe.dispatch(argv) end)

  test "company add + scoped agent add produce isolated handles" do
    pepe(["company", "add", "acme"])
    pepe(["company", "add", "globex"])
    assert Config.companies() == ["acme", "globex"]

    pepe(["agent", "add", "vendas", "--company", "acme", "--prompt", "a", "--tools", "bash"])
    pepe(["agent", "add", "vendas", "--company", "globex", "--prompt", "g", "--tools", "bash"])
    pepe(["agent", "add", "assistant", "--prompt", "root", "--tools", "bash"])

    # same bare name, two companies, independent
    assert Config.get_agent("acme/vendas").system_prompt == "a"
    assert Config.get_agent("globex/vendas").system_prompt == "g"

    # scoped listing
    assert Enum.map(Config.agents_in("acme"), & &1.name) == ["acme/vendas"]
    assert Enum.map(Config.agents_in(nil), & &1.name) == ["assistant"]

    # a company agent does not become the global default
    assert Config.default_agent_name() == "assistant"
  end

  test "agent add into a missing company is rejected" do
    out = pepe_err(["agent", "add", "vendas", "--company", "ghost", "--tools", "bash"])
    assert out =~ "unknown company"
    assert Config.get_agent("ghost/vendas") == nil
  end

  test "bare --can-message routes qualify into the agent's company" do
    pepe(["company", "add", "acme"])
    pepe(["agent", "add", "vendas", "--company", "acme", "--can-message", "suporte"])

    assert Config.get_agent("acme/vendas").can_message == ["acme/suporte"]
  end

  test "route refuses to cross companies" do
    pepe(["company", "add", "acme"])
    pepe(["company", "add", "globex"])
    pepe(["agent", "add", "a", "--company", "acme"])
    pepe(["agent", "add", "b", "--company", "globex"])

    out = pepe_err(["agent", "route", "acme/a", "globex/b"])
    assert out =~ "across companies"
    assert Config.get_agent("acme/a").can_message == []
  end

  test "company remove is guarded, --force cascades" do
    pepe(["company", "add", "acme"])
    pepe(["agent", "add", "vendas", "--company", "acme"])

    guarded = pepe_err(["company", "remove", "acme"])
    assert guarded =~ "still has 1 agent"
    assert Config.company_exists?("acme")

    pepe(["company", "remove", "acme", "--force"])
    refute Config.company_exists?("acme")
    assert Config.get_agent("acme/vendas") == nil
  end
end
