defmodule Pepe.Skills.LintTest do
  use ExUnit.Case, async: true

  alias Pepe.Skills.Lint

  test "a description containing a colon (\"Use when: ...\") is read as a real trigger, not treated as no header" do
    content = "---\nname: s\ndescription: Use when: the user sends a PDF\n---\n\nDo the thing.\n"

    findings = Lint.content(content, name: "s")

    refute Enum.any?(findings, &(&1.rule in [:no_trigger, :no_summary]))
  end
end
