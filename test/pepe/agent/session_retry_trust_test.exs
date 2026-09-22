defmodule Pepe.Agent.SessionRetryTrustTest do
  @moduledoc """
  Regression test for an independent safety review: `/retry` must resubmit a turn with
  the same trust context (`:untrusted`, `:sender_tag`) the original turn had, instead of
  silently defaulting to trusted - a document-derived Telegram turn, or a group message
  whose sender label is lost on retry, would otherwise regain pre-approved-tool trust or
  attribute an answer to the wrong person.
  """
  use ExUnit.Case, async: false

  alias Pepe.Agent.Session
  alias Pepe.Agent.SessionSupervisor
  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Config.Model

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_retry_trust_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    {:ok, server} = Bandit.start_link(plug: Pepe.Test.WriterLLM, port: 0, scheme: :http, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Config.put_model(%Model{name: "mock", base_url: "http://localhost:#{port}", api_key: "k", model: "mock-model"})
    Config.put_agent(%Agent{name: "trust", model: "mock", tools: [], auto_approve: ["*"], max_iterations: 3})

    on_exit(fn ->
      Process.exit(server, :normal)
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    on_exit(&Pepe.Test.Sessions.stop_all!/0)

    key = "trust:#{System.unique_integer([:positive])}"
    {:ok, _pid} = SessionSupervisor.ensure(key, "trust")

    {:ok, key: key}
  end

  test "retry returns the trust context of the original turn, not the default", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "a document's extracted text", untrusted: true, sender_tag: "alice")
    assert {:ok, %{untrusted: true, sender_tag: "alice"}} = Session.retry(key)
  end

  test "retry of an ordinary, trusted turn stays trusted with no sender", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "hello")
    assert {:ok, %{untrusted: false, sender_tag: nil}} = Session.retry(key)
  end

  test "retrying twice in a row keeps reporting the same original trust context", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "untrusted content", untrusted: true, sender_tag: "bob")
    assert {:ok, %{untrusted: true, sender_tag: "bob"}} = Session.retry(key)

    # retry/2 itself resubmits nothing - the caller does, with its own untrusted/sender_tag
    # opts. Re-sending it here the same way a gateway would, with the metadata retry gave
    # back, must still report the same metadata on a second retry.
    assert {:ok, _reply} = Session.chat(key, "untrusted content", untrusted: true, sender_tag: "bob")
    assert {:ok, %{untrusted: true, sender_tag: "bob"}} = Session.retry(key)
  end

  test "rewinding a turn that got a standing session grant forgets that grant too", %{key: key} do
    assert {:ok, _reply} = Session.chat(key, "hello")
    Pepe.Permissions.SessionStore.allow(key, "bash:deletes")
    assert Pepe.Permissions.SessionStore.member?(key, "bash")

    assert {:ok, 1} = Session.rewind(key, 1)

    refute Pepe.Permissions.SessionStore.member?(key, "bash")
  end
end
