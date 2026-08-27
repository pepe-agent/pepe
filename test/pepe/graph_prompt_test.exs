defmodule Pepe.Graph.PromptTest do
  @moduledoc """
  Pure functions only - no model, no I/O. `render/3` and `referenced_keys/1` back both
  `Pepe.Graph.Runner` (rendering a node's prompt) and `Pepe.Graph.import/2`'s validation
  (which references exist, for taint's per-key precision). `verdict/2` is the contract a
  `verifier` node's reply must satisfy to route anywhere at all.
  """
  use ExUnit.Case, async: true

  alias Pepe.Graph.Prompt

  describe "render/3" do
    test "{{input}} substitutes the run's input" do
      assert Prompt.render("write about {{input}}", %{}, "cats") == {:ok, "write about cats"}
    end

    test "nil input renders as an empty string, not the literal nil" do
      assert Prompt.render("start: {{input}}.", %{}, nil) == {:ok, "start: ."}
    end

    test "a bound state key substitutes its value" do
      assert Prompt.render("draft: {{draft}}", %{"draft" => "hello"}, nil) == {:ok, "draft: hello"}
    end

    test "a non-string state value is stringified" do
      assert Prompt.render("count: {{n}}", %{"n" => 3}, nil) == {:ok, "count: 3"}
    end

    test "a required (non-`?`, no default) reference to a missing key fails the run" do
      assert Prompt.render("draft: {{missing}}", %{}, nil) == {:error, {:unbound_ref, "missing"}}
    end

    test "a `?` reference to a missing key falls back to the fixed placeholder" do
      assert Prompt.render("critique: {{verify?}}", %{}, nil) == {:ok, "critique: (none yet)"}
    end

    test "a `?` reference to a bound key still uses the real value" do
      assert Prompt.render("critique: {{verify?}}", %{"verify" => "looks good"}, nil) == {:ok, "critique: looks good"}
    end

    test "a `|default:\"...\"` reference to a missing key uses the literal" do
      assert Prompt.render(~s({{topic|default:"widgets"}}), %{}, nil) == {:ok, "widgets"}
    end

    test "a `|default:\"...\"` reference to a bound key ignores the literal" do
      assert Prompt.render(~s({{topic|default:"widgets"}}), %{"topic" => "gadgets"}, nil) == {:ok, "gadgets"}
    end

    test "a template with no references at all renders unchanged" do
      assert Prompt.render("just plain text", %{}, "ignored") == {:ok, "just plain text"}
    end

    test "multiple references in one template all resolve" do
      template = "{{input}} / {{a}} / {{b?}}"
      assert Prompt.render(template, %{"a" => "x"}, "in") == {:ok, "in / x / (none yet)"}
    end
  end

  describe "referenced_keys/1" do
    test "nil returns no keys" do
      assert Prompt.referenced_keys(nil) == []
    end

    test "collects every {{key}} form, deduplicated, excluding input" do
      template = ~s({{input}} {{draft}} {{draft}} {{verify?}} {{topic|default:"x"}})
      assert Enum.sort(Prompt.referenced_keys(template)) == ["draft", "topic", "verify"]
    end

    test "a template with no references returns an empty list" do
      assert Prompt.referenced_keys("no refs here") == []
    end
  end

  describe "verdict/2" do
    test "matches when the last non-blank line is exactly a verdict word" do
      reply = "I reviewed the draft and it looks solid.\n\npass"
      assert Prompt.verdict(reply, %{"pass" => "publish", "fail" => "draft"}) == {:ok, "pass", "publish"}
    end

    test "trims whitespace, trailing punctuation, and normalizes case" do
      reply = "Looks good.\n  PASS.  \n"
      assert Prompt.verdict(reply, %{"pass" => "publish"}) == {:ok, "pass", "publish"}
    end

    test "a verdict word merely mentioned mid-text does not route on it" do
      reply = "I would say this should pass, but let me think it over.\nfail"
      assert Prompt.verdict(reply, %{"pass" => "publish", "fail" => "draft"}) == {:ok, "fail", "draft"}
    end

    test "a last line matching no verdict is an error, never a silent fallback" do
      reply = "not sure honestly"

      assert Prompt.verdict(reply, %{"pass" => "publish", "fail" => "draft"}) ==
               {:error, {:bad_verdict, "not sure honestly"}}
    end

    test "blank trailing lines are skipped when finding the last real line" do
      reply = "pass\n\n\n"
      assert Prompt.verdict(reply, %{"pass" => "publish"}) == {:ok, "pass", "publish"}
    end
  end
end
