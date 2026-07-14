defmodule Pepe.Permissions.PromptTest do
  @moduledoc """
  The shared vocabulary every gateway's native "may I run this?" prompt draws from
  (Telegram's inline keyboard, the CLI's arrow-key menu, ...) - if this breaks, it breaks
  silently on every surface at once, so it had zero coverage despite being the single
  most-reused module in the permission flow.
  """
  use ExUnit.Case, async: true

  alias Pepe.Permissions.Prompt
  alias Pepe.Permissions.Risk

  test "options/0 offers exactly the four decisions, in display order" do
    assert Prompt.options() == [:once, :session, :always, :deny]
  end

  test "every decision has a label and an outcome, and neither is blank" do
    for decision <- Prompt.options() do
      assert Prompt.label(decision) != ""
      assert Prompt.outcome(decision) != ""
    end
  end

  test "token/1 and from_token/1 round-trip every decision" do
    for decision <- Prompt.options() do
      assert Prompt.from_token(Prompt.token(decision)) == decision
    end
  end

  test "token/1 is a stable, locale-independent string (not the translated label)" do
    assert Prompt.token(:once) == "once"
    assert Prompt.token(:session) == "session"
    assert Prompt.token(:always) == "always"
    assert Prompt.token(:deny) == "deny"
  end

  test "from_token/1 defaults an unrecognized token to :deny - the safe default" do
    assert Prompt.from_token("garbage") == :deny
    assert Prompt.from_token("") == :deny
    # Also guards against a forged/tampered callback payload trying to smuggle in a decision
    # that was never actually offered.
    assert Prompt.from_token("always;rm -rf") == :deny
  end

  test "question/1 names the tool and includes its one-line summary when it has one" do
    # bash is a real builtin with a spec description.
    assert Prompt.question("bash") =~ "bash"
    assert Prompt.question("bash") =~ "?"
  end

  test "question/1 still asks cleanly about a tool with no known summary (e.g. an MCP tool)" do
    q = Prompt.question("mcp__unknownserver__sometool")
    assert q =~ "mcp__unknownserver__sometool"
    assert q =~ "?"
    # No dangling "— " left over from a missing description.
    refute q =~ "— ?"
  end

  test "scope_note/1 with no risks says the grant only covers risk-free calls" do
    note = Prompt.scope_note([])
    assert note =~ "no risk"
  end

  test "scope_note/1 with risks names them, using Risk's own labels" do
    note = Prompt.scope_note([:deletes, :network])
    assert note =~ Risk.label(:deletes)
    assert note =~ Risk.label(:network)
  end
end
