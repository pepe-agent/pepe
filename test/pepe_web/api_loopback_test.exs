defmodule PepeWeb.ApiLoopbackTest do
  @moduledoc """
  With no API tokens configured, the `/v1` API is open to same-machine callers but
  closed to remote ones, so a network-exposed server is never anonymous.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias PepeWeb.ApiAuth

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    home = Path.join(System.tmp_dir!(), "pepe_loopback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    # No "api_tokens" key: the API is unlocked, so the loopback rule applies.
    config = %{
      "default_agent" => "assistant",
      "agents" => %{"assistant" => %{"model" => "mock", "system_prompt" => "hi", "tools" => []}}
    }

    File.write!(Path.join(home, "config.json"), Jason.encode!(config))

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp call(remote_ip) do
    conn(:post, "/v1/chat/completions", "")
    |> Map.put(:remote_ip, remote_ip)
    |> ApiAuth.call(ApiAuth.init([]))
  end

  test "a loopback IPv4 caller is allowed with an unrestricted scope" do
    conn = call({127, 0, 0, 1})
    refute conn.halted
    assert conn.assigns.api_scope == :unrestricted
  end

  test "the IPv6 loopback ::1 is allowed" do
    conn = call({0, 0, 0, 0, 0, 0, 0, 1})
    refute conn.halted
    assert conn.assigns.api_scope == :unrestricted
  end

  test "a remote caller is refused with a 401" do
    conn = call({203, 0, 113, 7})
    assert conn.halted
    assert conn.status == 401
  end

  describe "loopback?/1" do
    test "classifies loopback and remote addresses" do
      assert ApiAuth.loopback?({127, 0, 0, 1})
      assert ApiAuth.loopback?({127, 4, 5, 6})
      assert ApiAuth.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
      assert ApiAuth.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      refute ApiAuth.loopback?({203, 0, 113, 7})
      refute ApiAuth.loopback?({10, 0, 0, 5})
      refute ApiAuth.loopback?({0, 0, 0, 0, 0, 0, 0, 2})
    end
  end
end
