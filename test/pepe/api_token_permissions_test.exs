defmodule Pepe.ApiTokenPermissionsTest do
  @moduledoc """
  What a token is allowed to do, and the rules that keep a mistake from minting a credential
  nobody meant to hand out.
  """
  use ExUnit.Case, async: false

  alias Pepe.ApiToken
  alias Pepe.Config

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_token_perms_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"agents" => %{"assistant" => %{"model" => "m", "system_prompt" => "hi", "tools" => []}}})
    )

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp token(id), do: Enum.find(Config.api_tokens(), &(&1["id"] == id))

  test "a token minted the old way may chat and may not read usage" do
    {:ok, raw, id} = Config.add_api_token(label: "plain")

    assert ApiToken.permissions(token(id)) == %{chat: true, usage: false, prices: "billable", usage_content: false}

    scope = Config.verify_api_token(raw)
    assert scope.chat
    refute scope.usage
  end

  test "the stored entry keeps its old shape when nothing was chosen" do
    {:ok, _raw, id} = Config.add_api_token(label: "plain")

    # Defaults live in ApiToken, not in every config.json - a plain token's entry is byte for
    # byte what it was before permissions existed.
    entry = token(id)
    refute Map.has_key?(entry, "chat")
    refute Map.has_key?(entry, "usage")
    refute Map.has_key?(entry, "prices")
  end

  test "a read-only billing token carries exactly the two permissions it was given" do
    {:ok, raw, _id} = Config.add_api_token(chat: false, usage: true, prices: "list")

    scope = Config.verify_api_token(raw)
    refute scope.chat
    assert scope.usage
    assert scope.prices == "list"
    refute scope.usage_content
  end

  test "an unknown price view falls back to the narrowest rather than being trusted" do
    {:ok, raw, _id} = Config.add_api_token(usage: true, prices: "everything")

    assert Config.verify_api_token(raw).prices == "billable"
  end

  test "a token that could do nothing is refused instead of minted" do
    assert Config.add_api_token(chat: false) == {:error, :no_permissions}
  end

  test "content without a usage read is refused instead of dangling" do
    assert Config.add_api_token(usage_content: true) == {:error, :content_needs_usage}
  end

  test "a widget token can never be given the billing record" do
    assert Config.add_api_token(agent: "assistant", widget: true, usage: true) ==
             {:error, :widget_cannot_read_usage}
  end

  describe "changing permissions afterwards" do
    setup do
      {:ok, raw, id} = Config.add_api_token(label: "client", usage: true, prices: "all", usage_content: true)
      {:ok, raw: raw, id: id}
    end

    test "narrowing the price view leaves the credential itself working", %{raw: raw, id: id} do
      assert Config.set_api_token_permissions(id, prices: "billable") == :ok

      scope = Config.verify_api_token(raw)
      assert scope.prices == "billable"
      assert scope.usage
    end

    test "an untouched permission is not reset by changing another", %{id: id} do
      assert Config.set_api_token_permissions(id, chat: false) == :ok

      perms = ApiToken.permissions(token(id))
      refute perms.chat
      assert perms.usage
      assert perms.usage_content
    end

    test "revoking the usage read takes the content permission with it", %{id: id} do
      assert Config.set_api_token_permissions(id, usage: false) == :ok

      perms = ApiToken.permissions(token(id))
      refute perms.usage
      refute perms.usage_content
    end

    test "a change that would leave the token useless is refused", %{id: id} do
      assert Config.set_api_token_permissions(id, chat: false, usage: false) == {:error, :no_permissions}
    end

    test "an unknown id is reported rather than silently doing nothing" do
      assert Config.set_api_token_permissions("nope", usage: true) == {:error, :not_found}
    end
  end
end
