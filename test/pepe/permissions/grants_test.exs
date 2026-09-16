defmodule Pepe.Permissions.GrantsTest do
  @moduledoc """
  The audit trail behind every standing "always allow" grant: `grant/5` writes both the
  actual `auto_approve` entry and a ledger row, `revoke/2` undoes one. Pins the tricky
  part explicitly: `auto_approve` is tool-granular (two grants for the same tool fold into
  one widened entry), so revoking any ledger row for that agent+tool must strip the whole
  entry and mark every sibling ledger row revoked too - never leave a stale "active" row
  pointing at a grant that no longer exists in config.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Permissions.Grants

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_grants_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{}))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    Config.put_agent(%Agent{name: "zak", system_prompt: "x", tools: ["bash"], auto_approve: []})
    :ok
  end

  test "grant/5 persists the auto_approve entry and records who/where/why" do
    assert :ok = Grants.grant("zak", "bash:deletes", "telegram", "telegram:842064390", "typed !sempre")

    assert "bash:deletes" in Config.get_agent("zak").auto_approve

    assert [record] = Grants.list("zak")
    assert record.agent == "zak"
    assert record.grant == "bash:deletes"
    assert record.source == "telegram"
    assert record.granted_by == "telegram:842064390"
    assert record.reason == "typed !sempre"
    assert is_nil(record.revoked_at)
  end

  test "grant/5 on an unknown agent reports the error and writes no ledger row" do
    assert {:error, :unknown_agent} = Grants.grant("ghost", "bash:any", "cli")
    assert Grants.list("ghost") == []
  end

  test "revoke/2 strips the tool's auto_approve entry and marks the row revoked" do
    Grants.grant("zak", "bash:deletes", "telegram")
    [record] = Grants.list("zak")

    assert {:ok, [revoked]} = Grants.revoke(record.id, "operator")
    assert revoked.id == record.id
    assert revoked.revoked_at
    assert revoked.revoked_by == "operator"
    refute "bash:deletes" in Config.get_agent("zak").auto_approve
  end

  test "revoking one of two merged grants for the same tool strips the whole entry and both ledger rows" do
    Grants.grant("zak", "bash:deletes", "telegram")
    Grants.grant("zak", "bash:network", "dashboard")

    # The two calls widened into a single merged entry, exactly as Grant.merge/2 documents.
    assert Config.get_agent("zak").auto_approve == ["bash:deletes+network"]
    [first, second] = Grants.list("zak") |> Enum.sort_by(& &1.created_at)

    assert {:ok, revoked} = Grants.revoke(first.id)
    assert Enum.map(revoked, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Config.get_agent("zak").auto_approve == []

    assert Grants.active("zak") == []
    assert Enum.all?(Grants.list("zak"), & &1.revoked_at)
  end

  test "revoking a grant for one tool leaves a different tool's standing grant alone" do
    Grants.grant("zak", "bash:any", "telegram")
    Grants.grant("zak", "edit_file:none", "telegram")
    [bash_record] = Enum.filter(Grants.list("zak"), &(&1.grant == "bash:any"))

    Grants.revoke(bash_record.id)

    auto = Config.get_agent("zak").auto_approve
    refute "bash:any" in auto
    assert "edit_file:none" in auto
  end

  test "revoke/2 on an unknown id" do
    assert {:error, :not_found} = Grants.revoke("does-not-exist")
  end

  test "revoking a grant for an agent that no longer exists refuses and leaves the ledger row untouched" do
    Config.put_agent(%Agent{name: "gone", system_prompt: "x", tools: ["bash"], auto_approve: []})
    Grants.grant("gone", "bash:any", "cli")
    [record] = Grants.list("gone")

    Config.delete_agent("gone")

    assert {:error, :unknown_agent} = Grants.revoke(record.id)

    # Not marked revoked: a config write that never happened must not be reflected as one
    # that did - a stale "active" row is the safer failure than a stale "revoked" one, but
    # the actual goal is neither: nothing changes when the underlying write fails.
    [still] = Grants.list("gone")
    assert is_nil(still.revoked_at)
  end

  test "revoke/2 on an already-revoked grant" do
    Grants.grant("zak", "bash:any", "cli")
    [record] = Grants.list("zak")
    Grants.revoke(record.id)

    assert {:error, :already_revoked} = Grants.revoke(record.id)
  end

  test "list/0 with no agent filter returns grants across every agent" do
    Config.put_agent(%Agent{name: "other", system_prompt: "x", tools: ["bash"], auto_approve: []})
    Grants.grant("zak", "bash:any", "cli")
    Grants.grant("other", "bash:any", "cli")

    assert Enum.map(Grants.list(), & &1.agent) |> Enum.sort() == ["other", "zak"]
  end

  test "active/1 excludes revoked rows but list/1 still shows them" do
    Grants.grant("zak", "bash:any", "cli")
    [record] = Grants.list("zak")
    Grants.revoke(record.id)

    assert Grants.active("zak") == []
    assert [_] = Grants.list("zak")
  end

  test "revoking a tool covered by the bare wildcard is refused instead of silently doing nothing" do
    Config.put_agent(%Agent{name: "owner", system_prompt: "x", tools: ["bash"], auto_approve: ["*"]})
    # A ledger row can exist for a specific tool even though "*" already covers it (e.g.
    # recorded before the agent was widened to "*", or granted redundantly).
    Grants.grant("owner", "bash:any", "telegram")
    [record] = Grants.list("owner")

    assert {:error, :wildcard_grant} = Grants.revoke(record.id)

    # Nothing changed: the wildcard still covers everything, and the ledger row is untouched.
    assert Config.get_agent("owner").auto_approve == ["*"]
    assert is_nil(Grants.get(record.id).revoked_at)
  end

  test "revoking clears the matching in-memory session grant, not just the persisted one" do
    Pepe.Permissions.SessionStore.allow("telegram:555", "bash:any")
    Pepe.Permissions.SessionStore.allow("telegram:555", "edit_file:none")
    Grants.grant("zak", "bash:any", "telegram", "telegram:555")
    [record] = Grants.list("zak")

    assert Pepe.Permissions.SessionStore.member?("telegram:555", "bash") == true

    Grants.revoke(record.id)

    refute Pepe.Permissions.SessionStore.member?("telegram:555", "bash")
    # A different tool's session grant is untouched - this must not be SessionStore.clear/1.
    assert Pepe.Permissions.SessionStore.member?("telegram:555", "edit_file")
  end

  test "active/1 stops counting a grant the moment something else strips it from auto_approve" do
    Grants.grant("zak", "bash:any", "cli")
    [record] = Grants.list("zak")
    assert Grants.active("zak") == [record]

    # Simulates a path that bypasses the ledger entirely (/approve clear, the dashboard
    # agent editor, a hand edit of config.json) - config.ex's Config.allow_tool/2 counterpart
    # for removal, called directly instead of through Grants.revoke/2.
    Config.revoke_tool("zak", "bash")

    assert Grants.active("zak") == []
    # list/1 (unfiltered) still shows it, unrevoked - it's a historical record, not "active".
    assert [%{revoked_at: nil}] = Grants.list("zak")
  end
end
