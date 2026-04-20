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

  test "company set updates only the flags given, and \"none\" clears a cap" do
    pepe(["company", "add", "acme"])

    pepe(["company", "set", "acme", "--budget", "100"])
    assert Config.company_budget("acme") == 100.0
    assert Config.company_message_limit("acme") == nil

    pepe(["company", "set", "acme", "--message-limit", "500"])
    # budget untouched by an unrelated --message-limit-only call
    assert Config.company_budget("acme") == 100.0
    assert Config.company_message_limit("acme") == 500

    pepe(["company", "set", "acme", "--budget", "none"])
    assert Config.company_budget("acme") == nil
    assert Config.company_message_limit("acme") == 500
  end

  test "company set on an unknown company errors" do
    out = pepe_err(["company", "set", "ghost", "--budget", "10"])
    assert out =~ "unknown company"
  end

  test "company set with no flags errors with usage" do
    pepe(["company", "add", "acme"])
    out = pepe_err(["company", "set", "acme"])
    assert out =~ "usage: mix pepe company set"
  end

  test "company reset-messages zeroes the count" do
    pepe(["company", "add", "acme"])
    Pepe.Usage.record_message("acme")
    Pepe.Usage.record_message("acme")

    out = pepe(["company", "reset-messages", "acme"])
    assert out =~ "was 2"
    assert Pepe.Usage.message_count_month_to_date("acme") == 0
  end

  test "company reset-messages on an unknown company errors" do
    out = pepe_err(["company", "reset-messages", "ghost"])
    assert out =~ "unknown company"
  end

  test "company reset-budget zeroes the spend count" do
    pepe(["company", "add", "acme", "--description", "x"])
    pepe(["company", "set", "acme", "--budget", "10"])

    out = pepe(["company", "reset-budget", "acme"])
    assert out =~ "reset"
    assert Pepe.Usage.month_to_date("acme") == 0.0
  end

  test "company reset-budget on an unknown company errors" do
    out = pepe_err(["company", "reset-budget", "ghost"])
    assert out =~ "unknown company"
  end

  test "company set root works even though root is never a real company" do
    refute Config.company_exists?("root")

    pepe(["company", "set", "root", "--budget", "50", "--message-limit", "200"])
    assert Config.company_budget(nil) == 50.0
    assert Config.company_message_limit(nil) == 200
    # A company's own caps are untouched.
    pepe(["company", "add", "acme"])
    assert Config.company_budget("acme") == nil
  end

  test "company reset-messages/reset-budget root work against root's own counters" do
    pepe(["company", "set", "root", "--message-limit", "5", "--budget", "10"])
    Pepe.Usage.record_message(nil)
    Pepe.Usage.record_message(nil)

    out = pepe(["company", "reset-messages", "root"])
    assert out =~ "was 2"
    assert Pepe.Usage.message_count_month_to_date(nil) == 0

    out = pepe(["company", "reset-budget", "root"])
    assert out =~ "reset"
    assert Pepe.Usage.month_to_date(nil) == 0.0
  end

  test "agent add --exempt-message-limit persists the exemption" do
    pepe(["agent", "add", "bot", "--exempt-message-limit"])
    assert Config.get_agent("bot").exempt_message_limit == true
  end

  test "agent add without the flag defaults to not exempt" do
    pepe(["agent", "add", "bot"])
    assert Config.get_agent("bot").exempt_message_limit == false
  end

  test "agent add --admin grants can_manage \"*\" without touching auto_approve" do
    out = pepe(["agent", "add", "boss", "--admin"])
    assert out =~ "can administer every agent"
    assert Config.get_agent("boss").can_manage == ["*"]
    assert Config.get_agent("boss").auto_approve == []
  end

  test "agent add without --tools grants every tool, admin or not" do
    pepe(["agent", "add", "boss", "--admin"])
    assert Config.get_agent("boss").tools == Pepe.Tools.names()
  end

  test "agent add --admin wins over an explicit --can-manage" do
    pepe(["agent", "add", "boss", "--admin", "--can-manage", "none"])
    assert Config.get_agent("boss").can_manage == ["*"]
  end

  test "agent add without --admin defaults can_manage to nil (itself only)" do
    pepe(["agent", "add", "bot"])
    assert Config.get_agent("bot").can_manage == nil
  end
end
