defmodule Pepe.NetTest do
  use ExUnit.Case, async: true

  alias Pepe.Net

  test "loopback? covers 127/8, ::1 and IPv4-mapped loopback" do
    assert Net.loopback?({127, 0, 0, 1})
    assert Net.loopback?({127, 5, 9, 200})
    assert Net.loopback?({0, 0, 0, 0, 0, 0, 0, 1})
    assert Net.loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
    refute Net.loopback?({192, 168, 0, 1})
    refute Net.loopback?({10, 0, 0, 1})
    refute Net.loopback?({0, 0, 0, 0})
  end

  test "cidr_match? handles IPv4 ranges, bare IPs and family mismatch" do
    assert Net.cidr_match?({10, 1, 2, 3}, "10.0.0.0/8")
    refute Net.cidr_match?({11, 1, 2, 3}, "10.0.0.0/8")
    assert Net.cidr_match?({192, 168, 1, 5}, "192.168.1.0/24")
    refute Net.cidr_match?({192, 168, 2, 5}, "192.168.1.0/24")
    # bare IP = exact match
    assert Net.cidr_match?({127, 0, 0, 1}, "127.0.0.1")
    refute Net.cidr_match?({127, 0, 0, 2}, "127.0.0.1")
    # an IPv4 address never matches an IPv6 spec
    refute Net.cidr_match?({10, 0, 0, 1}, "::1/128")
  end

  test "cidr_match? handles IPv6" do
    assert Net.cidr_match?({0, 0, 0, 0, 0, 0, 0, 1}, "::1/128")
    assert Net.cidr_match?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}, "2001:db8::/32")
    refute Net.cidr_match?({0x2001, 0xDB9, 0, 0, 0, 0, 0, 5}, "2001:db8::/32")
  end

  test "trusted? is any-of over the spec list; bad input is safe" do
    assert Net.trusted?({127, 0, 0, 1}, ["10.0.0.0/8", "127.0.0.1"])
    refute Net.trusted?({8, 8, 8, 8}, ["10.0.0.0/8", "127.0.0.1"])
    refute Net.trusted?({8, 8, 8, 8}, [])
    refute Net.cidr_match?({8, 8, 8, 8}, "not-an-ip")
  end

  test "internal? covers loopback, RFC1918, link-local/cloud-metadata, and IPv6 equivalents" do
    assert Net.internal?({127, 0, 0, 1})
    assert Net.internal?({10, 1, 2, 3})
    assert Net.internal?({172, 16, 0, 1})
    assert Net.internal?({192, 168, 1, 1})
    assert Net.internal?({169, 254, 169, 254})
    assert Net.internal?({0, 0, 0, 0, 0, 0, 0, 1})
    assert Net.internal?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
    assert Net.internal?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    # IPv4-mapped IPv6 private address
    assert Net.internal?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
    refute Net.internal?({8, 8, 8, 8})
    refute Net.internal?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 5})
  end
end
