defmodule Pepe.Permissions.GrantTest do
  @moduledoc """
  A permission remembers what it was given for.

  The first test is the whole feature: somebody approves bash while looking at a directory
  listing, and that approval does not quietly extend to `rm -rf`. Everything else here is
  about not breaking the installs that already exist, and about failing closed when we do
  not understand something.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Permissions
  alias Pepe.Permissions.Grant

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_grant_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp agent!(auto_approve) do
    agent = %Agent{name: "worker", model: "m", system_prompt: "hi", tools: ["bash"], auto_approve: auto_approve}
    Config.put_agent(agent)
    Config.get_agent("worker")
  end

  defp bash(command), do: Jason.encode!(%{"command" => command})

  # A gate with a human on the other end who says yes to everything, and counts.
  defp asking_ctx(agent) do
    test = self()

    %{
      agent: agent,
      session_key: "s:#{System.unique_integer([:positive])}",
      authorize: fn name, args, ctx ->
        send(test, {:asked, name, args, ctx[:risks]})
        :always
      end
    }
  end

  test "approving bash on a harmless command does not also approve rm -rf" do
    ctx = asking_ctx(agent!([]))

    # The human is looking at a directory listing when they say "always allow bash".
    assert :allow = Permissions.gate("bash", bash("ls build/"), ctx)
    assert_receive {:asked, "bash", _, []}

    # What got written down is what they were actually looking at.
    assert Config.get_agent("worker").auto_approve == ["bash:none"]

    # A second harmless call runs without asking. This is the part that has to keep working,
    # or people turn the gate off out of irritation and we have made things worse.
    ctx = %{ctx | agent: Config.get_agent("worker")}
    assert :allow = Permissions.gate("bash", bash("cat README.md"), ctx)
    refute_receive {:asked, _, _, _}, 50

    # And now the agent reaches for rm. Under the old gate this ran silently: the human had
    # said "always allow bash" and bash is bash. It stops and asks, and the question names
    # the thing nobody ever said yes to.
    assert :allow = Permissions.gate("bash", bash("rm -rf build/"), ctx)
    assert_receive {:asked, "bash", _, risks}
    assert :deletes in risks
  end

  test "the grant widens as you say yes, and does not pile up" do
    ctx = asking_ctx(agent!([]))

    Permissions.gate("bash", bash("ls"), ctx)
    ctx = %{ctx | agent: Config.get_agent("worker")}
    Permissions.gate("bash", bash("rm -rf tmp"), ctx)
    ctx = %{ctx | agent: Config.get_agent("worker")}
    Permissions.gate("bash", bash("curl https://example.com"), ctx)

    # One entry for bash, holding everything that was ever approved for it - not three
    # entries nobody can read.
    assert [grant] = Config.get_agent("worker").auto_approve
    assert {"bash", risks} = Grant.parse(grant)
    assert :deletes in risks
    assert :network in risks
  end

  test "an existing install keeps working: a bare tool name is still a blank cheque" do
    # Written by a Pepe from before any of this existed. Breaking it to make a point would
    # not be a security improvement, it would be a broken upgrade.
    ctx = asking_ctx(agent!(["bash"]))

    assert :allow = Permissions.gate("bash", bash("rm -rf /"), ctx)
    refute_receive {:asked, _, _, _}, 50
  end

  test "the wildcard still means everything" do
    ctx = asking_ctx(agent!(["*"]))

    assert :allow = Permissions.gate("bash", bash("sudo rm -rf /"), ctx)
    refute_receive {:asked, _, _, _}, 50

    # And it is left alone: an agent that already runs everything has nothing to widen.
    assert Config.get_agent("worker").auto_approve == ["*"]
  end

  test "a risk we do not recognise never widens a grant" do
    # An older Pepe, or a human, wrote something we have no meaning for. It must not match a
    # real risk, and it must not accidentally read as `any`.
    refute Grant.covers?(["bash:something_we_removed"], "bash", [:deletes])
    assert Grant.covers?(["bash:something_we_removed"], "bash", [])
  end

  describe "the strings that end up in config.json" do
    test "read like what they are" do
      assert Grant.for("bash", []) == "bash:none"
      assert Grant.for("bash", [:network, :deletes]) == "bash:deletes+network"

      assert Grant.describe("bash:none") =~ "no risk"
      assert Grant.describe("bash:any") =~ "anything"
      assert Grant.describe("*") =~ "every tool"
    end

    test "a call is covered when its risks are a subset of the grant's" do
      assert Grant.covers?(["bash:deletes+network"], "bash", [:deletes])
      assert Grant.covers?(["bash:deletes+network"], "bash", [])

      # Trusted to delete, never trusted to run as root.
      refute Grant.covers?(["bash:deletes+network"], "bash", [:deletes, :elevated])

      # A grant for one tool says nothing about another.
      refute Grant.covers?(["bash:any"], "write_file", [])
    end
  end
end
