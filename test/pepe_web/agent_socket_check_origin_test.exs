defmodule PepeWeb.AgentSocketCheckOriginTest do
  @moduledoc """
  `check_origin?/1` is what actually decides whether a browser's WebSocket handshake
  reaches `AgentSocket.connect/3` at all - it runs earlier, seeing only the parsed
  `Origin` header (see the moduledoc on the function for why). This is the one place
  that logic can be tested directly, without a real socket handshake.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias PepeWeb.AgentSocket

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_origin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  defp uri(str), do: URI.parse(str)

  test "an origin with no host is refused" do
    refute AgentSocket.check_origin?(%URI{host: nil})
  end

  test "the server's own configured host is always allowed" do
    host = Application.get_env(:pepe, PepeWeb.Endpoint)[:url][:host]
    assert is_binary(host)
    assert AgentSocket.check_origin?(uri("http://#{host}"))
  end

  test "an unregistered origin is refused" do
    refute AgentSocket.check_origin?(uri("https://not-registered.example"))
  end

  test "an origin registered by a widget token is allowed" do
    Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "x", tools: []})
    {:ok, _raw, _id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    assert AgentSocket.check_origin?(uri("https://example.com"))
  end

  test "a different origin than the one registered is refused" do
    Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "x", tools: []})
    {:ok, _raw, _id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    refute AgentSocket.check_origin?(uri("https://evil.example"))
  end

  test "matches regardless of an explicit default port" do
    Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "x", tools: []})
    {:ok, _raw, _id} = Config.add_api_token(agent: "assistant", widget: true, allowed_origin: "https://example.com")

    assert AgentSocket.check_origin?(uri("https://example.com:443"))
  end

  test "a non-widget token's origin (there isn't one) does not grant access" do
    Config.put_agent(%Pepe.Config.Agent{name: "assistant", system_prompt: "x", tools: []})
    {:ok, _raw, _id} = Config.add_api_token(agent: "assistant")

    refute AgentSocket.check_origin?(uri("https://example.com"))
  end
end
