defmodule Pepe.TunnelTest do
  use ExUnit.Case, async: true

  alias Pepe.Tunnel

  test "extract_url pulls the trycloudflare URL out of cloudflared output" do
    out = """
    2026-07-05 INF +--------------------------------------------------------+
    2026-07-05 INF |  https://happy-brave-cat-1234.trycloudflare.com        |
    2026-07-05 INF +--------------------------------------------------------+
    """

    assert Tunnel.extract_url(out) == "https://happy-brave-cat-1234.trycloudflare.com"
  end

  test "extract_url returns nil when there's no URL" do
    assert Tunnel.extract_url("just a normal log line") == nil
  end

  test "available? returns a boolean" do
    assert is_boolean(Tunnel.available?())
  end

  test "open reports a clear error when cloudflared is missing" do
    # only assert the not-found path when cloudflared really isn't installed
    unless Tunnel.available?() do
      assert Tunnel.open(4000, fn _ -> :ok end) == {:error, :cloudflared_not_found}
    end
  end
end
