defmodule Pepe.Presentation do
  @moduledoc """
  A small, provider-agnostic schema for structured reply content: a set of blocks each
  channel renders into its own native UI (Slack Block Kit, Discord embeds/components,
  ...) rather than every channel provider inventing its own ad hoc rich-content format.

  A block is a plain map with a `"type"`:

    * `%{"type" => "text", "text" => "..."}` - a plain paragraph.
    * `%{"type" => "table", "headers" => [...], "rows" => [[...], ...]}` - tabular data.
    * `%{"type" => "buttons", "buttons" => [%{"label" => "...", "value" => "..."}]}` -
      a row of choices. `value` is what comes back if the platform reports a click;
      providers that can't report clicks still render the labels as plain text.

  `Pepe.Webhooks.Provider`'s optional `deliver_blocks/3` callback is where a channel
  renders these natively. A provider that doesn't implement it - most, today - never
  sees a block at all: `Pepe.Webhooks.deliver_blocks/4` flattens them with `to_text/1`
  and sends the result through the provider's ordinary (required) `deliver/3`, so a
  plugin/tool that emits blocks works everywhere immediately, richly only where a
  provider has bothered to render them.
  """

  @type block :: map()

  @doc """
  Flatten `blocks` into a single plain-text message - the fallback for a channel with no
  `deliver_blocks/3`. Unrecognized block shapes are silently dropped rather than raising,
  since a tool building blocks from partially-trusted structured input (a plugin's own
  return value, say) shouldn't be able to crash delivery over one malformed block.
  """
  @spec to_text([block()]) :: String.t()
  def to_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_to_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  def to_text(_), do: ""

  defp block_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp block_to_text(%{"type" => "table", "headers" => headers, "rows" => rows})
       when is_list(headers) and is_list(rows) do
    header_line = Enum.join(headers, " | ")
    sep_line = Enum.map_join(headers, " | ", fn _ -> "---" end)
    row_lines = Enum.map(rows, &Enum.join(&1, " | "))
    Enum.join([header_line, sep_line | row_lines], "\n")
  end

  defp block_to_text(%{"type" => "buttons", "buttons" => buttons}) when is_list(buttons) do
    Enum.map_join(buttons, "\n", fn b -> "[#{b["label"] || b["value"]}]" end)
  end

  defp block_to_text(_other), do: nil

  @doc "Is `value` a syntactically valid block list (right shape, not necessarily renderable by every provider)?"
  @spec valid?(term()) :: boolean()
  def valid?(blocks) when is_list(blocks), do: Enum.all?(blocks, &valid_block?/1)
  def valid?(_), do: false

  defp valid_block?(%{"type" => "text", "text" => text}), do: is_binary(text)

  defp valid_block?(%{"type" => "table", "headers" => headers, "rows" => rows}) do
    is_list(headers) and Enum.all?(headers, &is_binary/1) and is_list(rows) and
      Enum.all?(rows, &(is_list(&1) and Enum.all?(&1, fn cell -> is_binary(cell) end)))
  end

  defp valid_block?(%{"type" => "buttons", "buttons" => buttons}) do
    is_list(buttons) and Enum.all?(buttons, &(is_map(&1) and is_binary(&1["label"])))
  end

  defp valid_block?(_), do: false
end
