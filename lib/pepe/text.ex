defmodule Pepe.Text do
  @moduledoc """
  Text helpers for strings that go to a model or into JSON, where a single invalid UTF-8
  byte is fatal (the request body or the trace row fails to encode).
  """

  @doc """
  Clip `text` to at most `max` bytes without splitting a multi-byte codepoint. A raw
  `binary_part/3` can cut one in half and leave invalid UTF-8 behind.
  """
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(text, max) when byte_size(text) <= max, do: text

  def truncate(text, max) do
    # A codepoint is at most 4 bytes, so backing off up to 3 finds a boundary.
    size = Enum.find(max..max(max - 3, 0)//-1, max, &String.valid?(binary_part(text, 0, &1)))
    binary_part(text, 0, size)
  end

  @doc "Replace any invalid UTF-8 byte with the replacement character."
  @spec scrub(binary()) :: binary()
  def scrub(text), do: if(String.valid?(text), do: text, else: String.replace_invalid(text))
end
