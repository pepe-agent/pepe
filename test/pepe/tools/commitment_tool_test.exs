defmodule Pepe.Tools.CommitmentTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Commitment
  alias Pepe.Tools.Commitment, as: CommitmentTool

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_committool_#{System.unique_integer([:positive])}")
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

  test "list says so when there's nothing active" do
    assert {:ok, "No active commitments."} = CommitmentTool.run(%{"action" => "list"}, %{})
  end

  test "list shows active commitments, not delivered/cancelled ones" do
    {:ok, _} = Config.create_commitment(%Commitment{text: "check the deploy", state: "scheduled", due_when: "tomorrow"})
    {:ok, done} = Config.create_commitment(%Commitment{text: "already sent", state: "scheduled"})
    Config.put_commitment(%{done | state: "delivered"})

    assert {:ok, out} = CommitmentTool.run(%{"action" => "list"}, %{})
    assert out =~ "check the deploy"
    refute out =~ "already sent"
  end

  test "confirm promotes an awaiting commitment that already has a resolved due date" do
    {:ok, c} =
      Config.create_commitment(%Commitment{
        text: "look into it",
        state: "awaiting_confirmation",
        due_when: "tomorrow",
        due_at: System.system_time(:second) + 86_400
      })

    assert {:ok, msg} = CommitmentTool.run(%{"action" => "confirm", "id" => c.id}, %{})
    assert msg =~ "Confirmed"
    assert Config.get_commitment(c.id).state == "scheduled"
  end

  test "confirm with an unresolved due date needs a due_when to proceed" do
    {:ok, c} = Config.create_commitment(%Commitment{text: "look into it", state: "awaiting_confirmation"})

    assert {:error, msg} = CommitmentTool.run(%{"action" => "confirm", "id" => c.id}, %{})
    assert msg =~ "due time"

    assert {:ok, _} = CommitmentTool.run(%{"action" => "confirm", "id" => c.id, "due_when" => "tomorrow"}, %{})
    updated = Config.get_commitment(c.id)
    assert updated.state == "scheduled"
    assert is_integer(updated.due_at)
  end

  test "confirm reports an unknown id clearly" do
    assert {:error, msg} = CommitmentTool.run(%{"action" => "confirm", "id" => "nope"}, %{})
    assert msg =~ "no commitment"
  end

  test "cancel deletes the commitment" do
    {:ok, c} = Config.create_commitment(%Commitment{text: "ping the user", state: "scheduled"})

    assert {:ok, msg} = CommitmentTool.run(%{"action" => "cancel", "id" => c.id}, %{})
    assert msg =~ "cancelled"
    assert Config.get_commitment(c.id) == nil
  end

  test "an action needing an id without one is refused with a clear message" do
    assert {:error, msg} = CommitmentTool.run(%{"action" => "confirm"}, %{})
    assert msg =~ "needs an `id`"
  end

  # A model reaching for "create" (there is no such action - commitments are only ever
  # noticed automatically) used to get the same generic "needs an `action`" error a
  # genuinely missing action gets, which reads as "you forgot the parameter" rather than
  # "that value doesn't exist" - so the model retried the identical broken call instead of
  # correcting course. This name-and-redirect message is specifically for that case.
  test "an unrecognized action is named and redirected, not confused with a missing one" do
    assert {:error, msg} = CommitmentTool.run(%{"action" => "create", "value" => "pay rent"}, %{})
    assert msg =~ "\"create\" isn't a real action"
    assert msg =~ "no tool call needed"
  end

  test "a genuinely missing action still gets its own distinct message" do
    assert {:error, msg} = CommitmentTool.run(%{}, %{})
    assert msg == "commitment needs an `action`"
  end
end
