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

  test "options/0 offers exactly the five decisions, in display order, when not tainted" do
    assert Prompt.options() == [:once, :session, :session_any, :always, :deny]
    assert Prompt.options(false) == [:once, :session, :session_any, :always, :deny]
  end

  test "options/1 with tainted: true inserts this_run, since a session/always tap does nothing until the next run" do
    assert Prompt.options(true) == [:once, :this_run, :session, :session_any, :always, :deny]
  end

  test "options/2 drops :session and :session_any when there is no session to remember them against" do
    assert Prompt.options(false, false) == [:once, :always, :deny]
    assert Prompt.options(true, false) == [:once, :this_run, :always, :deny]
    # Default (has_session? unset) stays true, so an existing 1-arity caller is unaffected.
    assert Prompt.options(false) == Prompt.options(false, true)
  end

  test "policy_note/1 is nil when nothing forced the ask, and includes the reason otherwise" do
    assert Prompt.policy_note(nil) == nil
    assert Prompt.policy_note("looks unusual") =~ "looks unusual"
  end

  test "every decision has a label and an outcome, and neither is blank" do
    for decision <- Prompt.options(true) do
      assert Prompt.label(decision) != ""
      assert Prompt.outcome(decision) != ""
    end
  end

  test "this_run's label is marked recommended only while tainted" do
    assert Prompt.label(:this_run, true) =~ "recommended"
    refute Prompt.label(:this_run, false) =~ "recommended"
    assert Prompt.label(:this_run) == Prompt.label(:this_run, false)
  end

  test "no other decision's label changes with taint" do
    for decision <- [:once, :session, :session_any, :always, :deny] do
      assert Prompt.label(decision, true) == Prompt.label(decision, false)
    end
  end

  test "session_any's label and outcome are clearly distinct from session's" do
    refute Prompt.label(:session_any) == Prompt.label(:session)
    refute Prompt.outcome(:session_any) == Prompt.outcome(:session)
    assert Prompt.label(:session_any) =~ "any parameters"
  end

  test "taint_note/0 names the exact button that actually stops the repeat prompts" do
    assert Prompt.taint_note() =~ "Allow for the rest of this task"
  end

  test "token/1 and from_token/1 round-trip every decision" do
    for decision <- Prompt.options(true) do
      assert Prompt.from_token(Prompt.token(decision)) == decision
    end
  end

  test "token/1 is a stable, locale-independent string (not the translated label)" do
    assert Prompt.token(:once) == "once"
    assert Prompt.token(:this_run) == "this_run"
    assert Prompt.token(:session) == "session"
    assert Prompt.token(:session_any) == "session_any"
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

  test "scope_note/1 always points out that \"any parameters\" is a different, wider option" do
    assert Prompt.scope_note([]) =~ "any parameters"
    assert Prompt.scope_note([:deletes]) =~ "any parameters"
  end
end
