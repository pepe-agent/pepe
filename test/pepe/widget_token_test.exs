defmodule Pepe.WidgetTokenTest do
  @moduledoc """
  A widget token's raw value is retrievable (it sits in public page source anyway),
  unlike a regular token's, which is never stored past creation.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_wtok_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    Config.put_agent(%Config.Agent{name: "assistant", system_prompt: "hi", tools: []})

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "a widget token's raw value round-trips through widget_token/1" do
    {:ok, raw, id} =
      Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    assert Config.widget_token(id) == raw
  end

  test "a regular token's raw value is never stored" do
    {:ok, _raw, id} = Config.add_api_token(agent: "assistant")

    assert Config.widget_token(id) == nil
    refute Map.has_key?(get_in(Config.load(), ["api_tokens", id]), "token")
  end

  test "widget_token/1 returns nil for an unknown id" do
    assert Config.widget_token("nope") == nil
  end

  describe "appearance" do
    test "set at creation, retrievable by raw value via widget_config/1" do
      {:ok, raw, _id} =
        Config.add_api_token(
          agent: "assistant",
          widget: true,
          allowed_origin: "https://example.com",
          title: "Support",
          color: "#123456",
          theme: "light",
          greeting: "Hey there!"
        )

      assert Config.widget_config(raw) == %{
               title: "Support",
               logo: nil,
               color: "#123456",
               theme: "light",
               greeting: "Hey there!",
               position: nil,
               allowed_origin: "https://example.com"
             }
    end

    test "widget_config/1 is nil for an unknown token, a revoked one, or a regular token" do
      refute Config.widget_config("pepe_nope")

      {:ok, raw, id} = Config.add_api_token(agent: "assistant", widget: true)
      Config.revoke_api_token(id)
      refute Config.widget_config(raw)

      {:ok, plain_raw, _id} = Config.add_api_token(agent: "assistant")
      refute Config.widget_config(plain_raw)
    end

    test "update_widget_token/2 edits appearance in place without touching the secret" do
      {:ok, raw, id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

      assert :ok = Config.update_widget_token(id, title: "New title", color: "#abcdef", label: "renamed")

      assert Config.widget_token(id) == raw
      assert Config.widget_config(raw).title == "New title"
      assert Config.widget_config(raw).color == "#abcdef"
      assert Enum.find(Config.api_tokens(), &(&1["id"] == id))["label"] == "renamed"
    end

    test "update_widget_token/2 refuses an unknown id or a non-widget token" do
      assert {:error, :not_found} = Config.update_widget_token("nope", title: "x")

      {:ok, _raw, id} = Config.add_api_token(agent: "assistant")
      assert {:error, :not_widget} = Config.update_widget_token(id, title: "x")
    end

    test "update_widget_token/2 leaves the label alone when the caller's opts don't include it" do
      {:ok, _raw, id} =
        Config.add_api_token(agent: "assistant", widget: true, label: "example.com widget")

      assert :ok = Config.update_widget_token(id, title: "New title")

      assert Enum.find(Config.api_tokens(), &(&1["id"] == id))["label"] == "example.com widget"
    end

    test "update_widget_token/2 does clear the label when the caller passes a blank one" do
      {:ok, _raw, id} = Config.add_api_token(agent: "assistant", widget: true, label: "example.com widget")

      assert :ok = Config.update_widget_token(id, label: "")

      assert Enum.find(Config.api_tokens(), &(&1["id"] == id))["label"] == nil
    end
  end
end
