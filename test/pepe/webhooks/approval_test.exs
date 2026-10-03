defmodule Pepe.Webhooks.ApprovalTest do
  @moduledoc """
  A permission question asked in the conversation and answered by typing, on a channel with no
  buttons. What matters: it is off unless the connection names its approvers, only an approver's
  exact reply settles it (and is then not a message for the agent), the wider grants cannot be
  typed, and a question nobody answers ends in a denial that says so.
  """
  use ExUnit.Case, async: false

  alias Pepe.Webhooks.Approval

  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Process.whereis(:approval_test), {:asked, to, text})
      :ok
    end
  end

  @key "fake:assistant:C1"
  @entry %{"slug" => "t", "provider" => "fake", "agent" => "assistant", "trainers" => ["boss"]}

  setup do
    Process.register(self(), :approval_test)
    Application.put_env(:pepe, :webhook_approval_timeout_ms, 2_000)

    on_exit(fn -> Application.delete_env(:pepe, :webhook_approval_timeout_ms) end)
    :ok
  end

  # The session's process is the one that waits, so the callback runs in its own.
  defp ask(entry, ctx \\ %{session_key: @key}) do
    authorize = Approval.authorizer(entry, FakeProvider, "C1", @key)
    task = Task.async(fn -> authorize.("bash", Jason.encode!(%{"command" => "ls /tmp"}), ctx) end)
    assert_receive {:asked, "C1", text}, 2_000
    {task, text}
  end

  test "without named approvers there is nothing to ask" do
    assert Approval.authorizer(Map.delete(@entry, "trainers"), FakeProvider, "C1", @key) == nil
    assert Approval.authorizer(%{@entry | "trainers" => []}, FakeProvider, "C1", @key) == nil
  end

  test "the question shows the real command and how to answer" do
    {task, text} = ask(@entry)
    assert text =~ "bash"
    assert text =~ "ls /tmp"
    assert text =~ "allow"
    Approval.reply(@entry, @key, "boss", "deny")
    Task.await(task)
  end

  test "an approver's exact reply settles it and is consumed" do
    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "boss", "Allow") == :consumed
    assert Task.await(task) == :once
  end

  test "allow all and allow session can be typed, with their own decisions" do
    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "boss", "allow all") == :consumed
    assert Task.await(task) == :this_run

    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "boss", "permitir sessão") == :consumed
    assert Task.await(task) == :session_any
  end

  test "someone who is not an approver cannot answer, and their message passes through" do
    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "stranger", "allow") == :pass
    assert Approval.reply(@entry, @key, "boss", "deny") == :consumed
    assert Task.await(task) == :deny
  end

  test "the two widest grants cannot be typed here" do
    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "boss", "!always") == :pass
    assert Approval.reply(@entry, @key, "boss", "allow everything session") == :pass
    Approval.reply(@entry, @key, "boss", "deny")
    Task.await(task)
  end

  test "a reply with no question waiting, or an ordinary message, passes" do
    assert Approval.reply(@entry, @key, "boss", "allow") == :pass
    {task, _} = ask(@entry)
    assert Approval.reply(@entry, @key, "boss", "can you explain what it does first?") == :pass
    Approval.reply(@entry, @key, "boss", "deny")
    Task.await(task)
  end

  test "trainers [\"*\"] lets anyone in the conversation answer" do
    entry = %{@entry | "trainers" => ["*"]}
    {task, _} = ask(entry)
    assert Approval.reply(entry, @key, "anyone", "allow") == :consumed
    assert Task.await(task) == :once
  end

  test "an unanswered question is denied, saying that nobody answered" do
    Application.put_env(:pepe, :webhook_approval_timeout_ms, 50)
    {task, _} = ask(@entry)
    assert {:deny, reason} = Task.await(task)
    assert reason =~ "expired"
  end

  test "the waiting is cleaned up, so the next question can be asked" do
    {task, _} = ask(@entry)
    Approval.reply(@entry, @key, "boss", "allow")
    Task.await(task)
    {task, _} = ask(@entry)
    Approval.reply(@entry, @key, "boss", "deny")
    assert Task.await(task) == :deny
  end
end
