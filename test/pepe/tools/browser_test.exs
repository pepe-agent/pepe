defmodule Pepe.Tools.BrowserTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Tools.Browser

  test "spec advertises the six actions" do
    spec = Browser.spec()
    enum = get_in(spec, ["function", "parameters", "properties", "action", "enum"])
    assert enum == ~w(open snapshot click type press close)
  end

  test "requires an action" do
    assert {:error, msg} = Browser.run(%{}, %{})
    assert msg =~ "action"
  end

  test "open dispatches to Pepe.Browser.open with the session key" do
    Mimic.expect(Pepe.Browser, :open, fn "telegram:1", "https://example.com" -> {:ok, "snapshot text"} end)

    assert {:ok, "snapshot text"} =
             Browser.run(%{"action" => "open", "url" => "https://example.com"}, %{session_key: "telegram:1"})
  end

  test "open without a url errors before reaching Pepe.Browser" do
    assert {:error, msg} = Browser.run(%{"action" => "open"}, %{session_key: "s"})
    assert msg =~ "url"
  end

  test "falls back to an oneshot session key derived from the agent when there's no session_key" do
    Mimic.expect(Pepe.Browser, :snapshot, fn "oneshot:default/assistant" -> {:ok, "page"} end)

    ctx = %{agent: %{name: "default/assistant"}}
    assert {:ok, "page"} = Browser.run(%{"action" => "snapshot"}, ctx)
  end

  test "click dispatches with the ref" do
    Mimic.expect(Pepe.Browser, :click, fn "s", 3 -> {:ok, "clicked"} end)
    assert {:ok, "clicked"} = Browser.run(%{"action" => "click", "ref" => 3}, %{session_key: "s"})
  end

  test "click without a ref errors" do
    assert {:error, msg} = Browser.run(%{"action" => "click"}, %{session_key: "s"})
    assert msg =~ "ref"
  end

  test "type dispatches with ref and text" do
    Mimic.expect(Pepe.Browser, :type, fn "s", 1, "hello" -> {:ok, "typed"} end)
    assert {:ok, "typed"} = Browser.run(%{"action" => "type", "ref" => 1, "text" => "hello"}, %{session_key: "s"})
  end

  test "type without text errors" do
    assert {:error, msg} = Browser.run(%{"action" => "type", "ref" => 1}, %{session_key: "s"})
    assert msg =~ "text"
  end

  test "press dispatches with an optional ref" do
    Mimic.expect(Pepe.Browser, :press, fn "s", nil, "Enter" -> {:ok, "pressed"} end)
    assert {:ok, "pressed"} = Browser.run(%{"action" => "press", "key" => "Enter"}, %{session_key: "s"})
  end

  test "press without a key errors" do
    assert {:error, msg} = Browser.run(%{"action" => "press"}, %{session_key: "s"})
    assert msg =~ "key"
  end

  test "close dispatches with just the session key" do
    Mimic.expect(Pepe.Browser, :close, fn "s" -> {:ok, "browser session closed"} end)
    assert {:ok, "browser session closed"} = Browser.run(%{"action" => "close"}, %{session_key: "s"})
  end

  test "unknown action errors" do
    assert {:error, msg} = Browser.run(%{"action" => "teleport"}, %{session_key: "s"})
    assert msg =~ "unknown action"
  end

  test "is registered as a builtin tool, not always-safe" do
    assert Pepe.Tools.by_name()["browser"] == Browser
    assert Pepe.Permissions.requires_approval?("browser")
  end
end
