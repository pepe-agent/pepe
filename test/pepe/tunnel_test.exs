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

  describe "truncate/2" do
    test "leaves a binary shorter than max untouched" do
      assert Tunnel.truncate("hello", 100) == "hello"
    end

    test "keeps only the last `max` bytes of a longer binary" do
      assert Tunnel.truncate("hello world", 5) == "world"
    end

    test "is byte-safe on content that isn't valid UTF-8" do
      garbage = <<0xFF, 0xFE, 1, 2, 3, "hello">>
      assert Tunnel.truncate(garbage, 3) == "llo"
    end

    test "combined with extract_url, recovers a URL split across two chunks" do
      part1 = "2026-07-05 INF |  https://happy-brave-cat-"
      part2 = "1234.trycloudflare.com        |\n"

      buffer = Tunnel.truncate(part1, 8192)
      refute Tunnel.extract_url(buffer)

      buffer = Tunnel.truncate(buffer <> part2, 8192)
      assert Tunnel.extract_url(buffer) == "https://happy-brave-cat-1234.trycloudflare.com"
    end
  end
end
