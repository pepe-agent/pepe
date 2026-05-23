defmodule Pepe.Tools.ManageTokenTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Agent
  alias Pepe.Tools.ManageToken

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_tok_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    config = %{
      "companies" => %{"buskaza" => %{}},
      "agents" => %{
        "assistant" => %{"model" => "m", "system_prompt" => "x", "tools" => []},
        "buskaza/default" => %{"model" => "m", "system_prompt" => "x", "tools" => []}
      }
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp ctx, do: %{agent: %Agent{name: "boss"}}

  test "create mints a token, shows the raw secret once, and locks the API" do
    assert {:ok, out} = ManageToken.run(%{"action" => "create", "label" => "chatwoot"}, ctx())
    assert out =~ "pepe_"
    assert out =~ "not be shown again"
    # The token is now stored (only its hash) and the API is locked.
    assert Config.api_auth_required?()
    assert [token] = Config.api_tokens()
    assert token["label"] == "chatwoot"
    refute Map.has_key?(token, "raw")
  end

  test "a project-scoped token records its project" do
    assert {:ok, out} = ManageToken.run(%{"action" => "create", "project" => "buskaza"}, ctx())
    assert out =~ "project buskaza"
    assert [token] = Config.api_tokens()
    assert token["project"] == "buskaza"
  end

  test "an agent outside the project is refused" do
    args = %{"action" => "create", "project" => "buskaza", "agent" => "assistant"}
    assert {:error, msg} = ManageToken.run(args, ctx())
    assert msg =~ "not in project"
    assert Config.api_tokens() == []
  end

  test "list never exposes the secret or hash" do
    {:ok, _} = ManageToken.run(%{"action" => "create", "label" => "one"}, ctx())
    assert {:ok, out} = ManageToken.run(%{"action" => "list"}, ctx())
    assert out =~ "one"
    assert out =~ "pepe_"
    refute out =~ "hash"
  end

  test "revoke deletes a token by id" do
    {:ok, _} = ManageToken.run(%{"action" => "create"}, ctx())
    [%{"id" => id}] = Config.api_tokens()

    assert {:ok, out} = ManageToken.run(%{"action" => "revoke", "id" => id}, ctx())
    assert out =~ "revoked"
    assert Config.api_tokens() == []
  end

  test "revoking an unknown id is an error" do
    assert {:error, msg} = ManageToken.run(%{"action" => "revoke", "id" => "nope"}, ctx())
    assert msg =~ "no token"
  end

  test "without a calling agent it refuses" do
    assert {:error, _} = ManageToken.run(%{"action" => "create"}, %{})
  end

  describe "widget tokens" do
    test "requires an agent" do
      args = %{"action" => "create", "widget" => true}
      assert {:error, msg} = ManageToken.run(args, ctx())
      assert msg =~ "agent-locked"
      assert Config.api_tokens() == []
    end

    test "mints one with an agent and an allowed_origin" do
      args = %{
        "action" => "create",
        "widget" => true,
        "agent" => "assistant",
        "allowed_origin" => "https://example.com"
      }

      assert {:ok, out} = ManageToken.run(args, ctx())
      assert out =~ "widget"
      assert out =~ "https://example.com"

      assert [token] = Config.api_tokens()
      assert token["kind"] == "widget"
      assert token["allowed_origin"] == "https://example.com"
      assert token["agent"] == "default/assistant"
    end

    test "list shows the widget badge and origin" do
      {:ok, _} =
        ManageToken.run(
          %{"action" => "create", "widget" => true, "agent" => "assistant", "allowed_origin" => "https://example.com"},
          ctx()
        )

      assert {:ok, out} = ManageToken.run(%{"action" => "list"}, ctx())
      assert out =~ "widget"
      assert out =~ "https://example.com"
    end

    test "create accepts appearance fields, and list shows the raw token (not just a fingerprint)" do
      args = %{
        "action" => "create",
        "widget" => true,
        "agent" => "assistant",
        "title" => "Support",
        "color" => "#123456"
      }

      assert {:ok, out} = ManageToken.run(args, ctx())
      refute out =~ "not be shown again"
      assert out =~ "list shows it again"

      [token] = Config.api_tokens()
      assert token["title"] == "Support"
      assert token["color"] == "#123456"

      assert {:ok, list_out} = ManageToken.run(%{"action" => "list"}, ctx())
      assert list_out =~ token["token"]
    end

    test "update edits appearance in place without needing the id twice" do
      {:ok, create_out} = ManageToken.run(%{"action" => "create", "widget" => true, "agent" => "assistant"}, ctx())
      [token] = Config.api_tokens()
      assert create_out =~ token["token"]

      args = %{"action" => "update", "id" => token["id"], "title" => "New title", "theme" => "light"}
      assert {:ok, _out} = ManageToken.run(args, ctx())

      [updated] = Config.api_tokens()
      assert updated["title"] == "New title"
      assert updated["theme"] == "light"
      # The secret itself never changes.
      assert updated["token"] == token["token"]
    end

    test "update refuses a non-widget token or an unknown id" do
      {:ok, _} = ManageToken.run(%{"action" => "create", "label" => "plain"}, ctx())
      [token] = Config.api_tokens()

      assert {:error, msg} = ManageToken.run(%{"action" => "update", "id" => token["id"], "title" => "x"}, ctx())
      assert msg =~ "isn't a widget token"

      assert {:error, _} = ManageToken.run(%{"action" => "update", "id" => "nope", "title" => "x"}, ctx())
    end
  end
end
