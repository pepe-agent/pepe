defmodule Pepe.Permissions.TextDecisionTest do
  @moduledoc "A typed reply is an answer only when it is exactly one of the known words."
  use ExUnit.Case, async: true

  alias Pepe.Permissions.TextDecision

  test "the plain words map to their decision, in any language and case" do
    assert TextDecision.parse("allow") == :once
    assert TextDecision.parse("  Permitir  ") == :once
    assert TextDecision.parse("ALLOW ALL") == :this_run
    assert TextDecision.parse("permitir sessão") == :session_any
    assert TextDecision.parse("permitir sessao") == :session_any
    assert TextDecision.parse("não") == :deny
    assert TextDecision.parse("no") == :deny
  end

  test "a word inside a longer message is not an answer" do
    assert TextDecision.parse("no, wait, what does that do?") == nil
    assert TextDecision.parse("I would allow it if you explain") == nil
    assert TextDecision.parse("") == nil
  end

  test "always needs a leading bang, so a typo can never land on it" do
    assert TextDecision.parse("!always") == :always
    assert TextDecision.parse("!sempre") == :always
    assert TextDecision.parse("always") == nil
    assert TextDecision.parse("sempre") == nil
  end
end
