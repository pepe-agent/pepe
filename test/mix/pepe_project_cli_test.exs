defmodule Mix.Tasks.PepeProjectCliTest do
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

  test "project add + scoped agent add produce isolated handles" do
    pepe(["project", "add", "acme"])
    pepe(["project", "add", "globex"])
    assert Config.project_slugs() == ["acme", "globex"]

    pepe(["agent", "add", "vendas", "--project", "acme", "--prompt", "a", "--tools", "bash"])
    pepe(["agent", "add", "vendas", "--project", "globex", "--prompt", "g", "--tools", "bash"])
    pepe(["agent", "add", "assistant", "--prompt", "root", "--tools", "bash"])

    # same bare name, two projects, independent
    assert Config.get_agent("acme/vendas").system_prompt == "a"
    assert Config.get_agent("globex/vendas").system_prompt == "g"

    # scoped listing
    assert Enum.map(Config.agents_in("acme"), & &1.name) == ["acme/vendas"]
    assert Enum.map(Config.agents_in(nil), & &1.name) == ["default/assistant"]

    # a project agent does not become the global default
    assert Config.default_agent_name() == "default/assistant"
  end

  test "agent add into a missing project is rejected" do
    out = pepe_err(["agent", "add", "vendas", "--project", "ghost", "--tools", "bash"])
    assert out =~ "unknown project"
    assert Config.get_agent("ghost/vendas") == nil
  end

  test "bare --can-message routes qualify into the agent's project" do
    pepe(["project", "add", "acme"])
    pepe(["agent", "add", "vendas", "--project", "acme", "--can-message", "suporte"])

    assert Config.get_agent("acme/vendas").can_message == ["acme/suporte"]
  end

  test "route refuses to cross projects" do
    pepe(["project", "add", "acme"])
    pepe(["project", "add", "globex"])
    pepe(["agent", "add", "a", "--project", "acme"])
    pepe(["agent", "add", "b", "--project", "globex"])

    out = pepe_err(["agent", "route", "acme/a", "globex/b"])
    assert out =~ "across projects"
    assert Config.get_agent("acme/a").can_message == []
  end

  test "project remove is guarded, --force cascades" do
    pepe(["project", "add", "acme"])
    pepe(["agent", "add", "vendas", "--project", "acme"])

    guarded = pepe_err(["project", "remove", "acme"])
    assert guarded =~ "still has 1 agent"
    assert Config.project_exists?("acme")

    pepe(["project", "remove", "acme", "--force"])
    refute Config.project_exists?("acme")
    assert Config.get_agent("acme/vendas") == nil
  end

  test "project set updates only the flags given, and \"none\" clears a cap" do
    pepe(["project", "add", "acme"])

    pepe(["project", "set", "acme", "--budget", "100"])
    assert Config.project_budget("acme") == 100.0
    assert Config.project_message_limit("acme") == nil

    pepe(["project", "set", "acme", "--message-limit", "500"])
    # budget untouched by an unrelated --message-limit-only call
    assert Config.project_budget("acme") == 100.0
    assert Config.project_message_limit("acme") == 500

    pepe(["project", "set", "acme", "--budget", "none"])
    assert Config.project_budget("acme") == nil
    assert Config.project_message_limit("acme") == 500
  end

  test "project set on an unknown project errors" do
    out = pepe_err(["project", "set", "ghost", "--budget", "10"])
    assert out =~ "unknown project"
  end

  test "project set with no flags errors with usage" do
    pepe(["project", "add", "acme"])
    out = pepe_err(["project", "set", "acme"])
    assert out =~ "usage: mix pepe project set"
  end

  test "project reset-messages zeroes the count" do
    pepe(["project", "add", "acme"])
    Pepe.Usage.record_message("acme")
    Pepe.Usage.record_message("acme")

    out = pepe(["project", "reset-messages", "acme"])
    assert out =~ "was 2"
    assert Pepe.Usage.message_count_month_to_date("acme") == 0
  end

  test "project reset-messages on an unknown project errors" do
    out = pepe_err(["project", "reset-messages", "ghost"])
    assert out =~ "unknown project"
  end

  test "project reset-budget zeroes the spend count" do
    pepe(["project", "add", "acme", "--description", "x"])
    pepe(["project", "set", "acme", "--budget", "10"])

    out = pepe(["project", "reset-budget", "acme"])
    assert out =~ "reset"
    assert Pepe.Usage.month_to_date("acme") == 0.0
  end

  test "project reset-budget on an unknown project errors" do
    out = pepe_err(["project", "reset-budget", "ghost"])
    assert out =~ "unknown project"
  end

  test "project set root works even though root is never a real project" do
    refute Config.project_exists?("root")

    pepe(["project", "set", "root", "--budget", "50", "--message-limit", "200"])
    assert Config.project_budget(nil) == 50.0
    assert Config.project_message_limit(nil) == 200
    # A project's own caps are untouched.
    pepe(["project", "add", "acme"])
    assert Config.project_budget("acme") == nil
  end

  test "project reset-messages/reset-budget root work against root's own counters" do
    pepe(["project", "set", "root", "--message-limit", "5", "--budget", "10"])
    Pepe.Usage.record_message(nil)
    Pepe.Usage.record_message(nil)

    out = pepe(["project", "reset-messages", "root"])
    assert out =~ "was 2"
    assert Pepe.Usage.message_count_month_to_date(nil) == 0

    out = pepe(["project", "reset-budget", "root"])
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
