defmodule Pepe.Skills.CommandsTest do
  use ExUnit.Case, async: false

  alias Pepe.Skills.Commands
  alias Pepe.Skills.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skill_commands_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    File.write!(Path.join([home, "skills", "read-pdf.md"]), "Use when reading a PDF.\n")
    File.write!(Path.join([home, "skills", "deploy.md"]), "Use when deploying.\n")
    File.write!(Path.join([home, "skills", "new.md"]), "Use when it collides with /new.\n")

    %{home: home}
  end

  @holds_skill %{tools: ["skill", "bash"]}

  defp commands(opts \\ []), do: [agent: @holds_skill] |> Keyword.merge(opts) |> Commands.list() |> Enum.map(& &1.command)

  test "every visible skill is offered, in the spelling every chat surface accepts" do
    assert "read_pdf" in commands()
    assert "deploy" in commands()
  end

  test "an agent without the skill tool is offered none, since it could not open them" do
    assert Commands.list(agent: %{tools: ["bash"]}) == []
  end

  test "an agent with no known tool list is not gated" do
    assert "deploy" in (Commands.list(agent: nil) |> Enum.map(& &1.command))
  end

  test "a built-in command name is never shadowed by a skill" do
    refute "new" in commands(reserved: ["new", "undo"])
    assert "new" in commands()
  end

  test "a disabled skill, or one disabled on this channel, is absent" do
    Settings.disable("deploy", nil)
    refute "deploy" in commands()

    Settings.enable("deploy", nil)
    Settings.disable("read-pdf", "telegram")
    refute "read_pdf" in commands(channel: "telegram")
    assert "read_pdf" in commands(channel: "tui")
  end

  test "find/2 accepts the name, the command form and a leading slash" do
    assert {:ok, %{name: "read-pdf"}} = Commands.find("read-pdf", agent: @holds_skill)
    assert {:ok, %{name: "read-pdf"}} = Commands.find("read_pdf", agent: @holds_skill)
    assert {:ok, %{name: "read-pdf"}} = Commands.find("/READ_PDF", agent: @holds_skill)
    assert Commands.find("nope", agent: @holds_skill) == :none
  end

  test "find/2 ignores the reserved list, so /skill <name> still reaches a shadowed skill" do
    assert {:ok, %{name: "new"}} = Commands.find("new", agent: @holds_skill, reserved: ["new"])
  end

  test "the turn a command runs asks the agent to carry the skill out, with the input" do
    assert Commands.instruction("deploy", "") == ~s(Carry out the "deploy" skill now.)
    assert Commands.instruction("deploy", "  staging  ") == ~s(Carry out the "deploy" skill now.\n\nInput: staging)
  end

  test "command_form/1 keeps to lowercase letters, digits and underscore, at most 32 characters" do
    assert Commands.command_form("Read-PDF v2!") == "read_pdf_v2"
    assert Commands.command_form(String.duplicate("a", 40)) |> String.length() == 32
  end

  test "a skill that lacks something it declared is still offered, with the note" do
    File.write!(
      Path.join([Pepe.Skills.user_dir(), "needs-key.md"]),
      "---\nname: needs-key\ndescription: Use when calling the API.\nrequired_environment_variables: [PEPE_TEST_SURELY_UNSET_KEY]\n---\n\nbody\n"
    )

    entry = Enum.find(Commands.list(agent: @holds_skill), &(&1.name == "needs-key"))
    assert entry.needs == "needs PEPE_TEST_SURELY_UNSET_KEY"
  end
end
