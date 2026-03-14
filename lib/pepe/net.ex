defmodule Pepe.Net do
  @moduledoc """
  Small, pure IP helpers shared by the dashboard's network defenses: loopback
  detection, address parsing, and CIDR / trusted-proxy matching (IPv4 and IPv6).
  No Plug/conn awareness lives here - see `PepeWeb.RemoteClient` for that.
  """
  import Bitwise

  @doc "True for 127.0.0.0/8, IPv6 ::1, and IPv4-mapped ::ffff:127.x."
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?({0, 0, 0, 0, 0, 0xFFFF, hi, _lo}), do: bsr(hi, 8) == 127
  def loopback?(_), do: false

  @doc "Parse a string into an `:inet` address tuple. `{:ok, tuple}` or `:error`."
  def parse_address(s) when is_binary(s) do
    case :inet.parse_address(String.to_charlist(String.trim(s))) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> :error
    end
  end

  def parse_address(_), do: :error

  @doc "Is `ip` (a tuple) inside any of the given CIDR / bare-IP specs?"
  def trusted?(ip, specs) when is_tuple(ip) and is_list(specs) do
    Enum.any?(specs, &cidr_match?(ip, &1))
  end

  @doc """
  Does `ip` (a tuple) fall inside `spec`? `spec` is `"10.0.0.0/8"`, `"::1/128"`, or a
  bare address (treated as a full-length prefix, i.e. an exact match). Families must
  match (an IPv4 ip never matches an IPv6 spec).
  """
  def cidr_match?(ip, spec) when is_tuple(ip) and is_binary(spec) do
    {base_str, prefix} = split_spec(spec)

    with {:ok, base} <- parse_address(base_str),
         true <- tuple_size(base) == tuple_size(ip) do
      {_bits_per, total} = bits(ip)
      prefix = prefix || total
      mask = mask(total, prefix)
      band(to_int(base), mask) == band(to_int(ip), mask)
    else
      _ -> false
    end
  end

  def cidr_match?(_, _), do: false

  defp split_spec(spec) do
    case String.split(spec, "/", parts: 2) do
      [base, p] -> {base, parse_prefix(p)}
      [base] -> {base, nil}
    end
  end

  defp parse_prefix(p) do
    case Integer.parse(p) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp bits({_, _, _, _}), do: {8, 32}
  defp bits(_), do: {16, 128}

  defp to_int(tuple) do
    {width, _total} = bits(tuple)

    Enum.reduce(Tuple.to_list(tuple), 0, fn part, acc -> bor(bsl(acc, width), part) end)
  end

  # Top `prefix` bits set, within a `total`-bit space (clamped to [0, total]).
  defp mask(total, prefix) do
    prefix = prefix |> max(0) |> min(total)
    low = total - prefix
    bxor(bsl(1, total) - 1, bsl(1, low) - 1)
  end
end
