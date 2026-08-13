defmodule Pepe.Tools.ReadFile do
  @moduledoc "Read a file from disk."
  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  # `read_file` is exempt from the generic spill-to-disk in `Pepe.Tools` (spilling a
  # read to a file the model then reads back would loop), so without its own cap a
  # large file would enter the history in full and be re-sent on every remaining loop
  # iteration. Instead of spilling, the model pages through the file with
  # `offset`/`limit`.
  #
  # The cap is sized to the running model, not fixed: each extra `read_file` call
  # re-sends the whole accumulated history, so on a big-window model many small pages
  # cost far more total tokens than one big page (measured live: a 212KB file at a
  # fixed 30KB cap took 9 calls and ~5x the tokens of a single uncapped read). The
  # page is ~10% of the context window at ~4 bytes/token, clamped to
  # [@floor_bytes, @ceiling_bytes] so a tiny window still gets a useful page and a
  # huge one can't be swamped by a single tool result.
  @floor_bytes 32_000
  @ceiling_bytes 128_000
  # No model in ctx (direct `Pepe.Tools.execute/2`, tests): the old fixed cap.
  @fallback_bytes 30_000

  @impl true
  def name, do: "read_file"

  @impl true
  def spec do
    function(
      "read_file",
      "Read the contents of a text file. Large files are truncated; use offset/limit to read them in slices.",
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "File path. Relative paths are in your persistent workspace; use shared/... for the shared space, or an absolute path."
          },
          "offset" => %{
            "type" => "integer",
            "description" => "1-based line number to start reading from (optional)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return (optional)."
          }
        },
        "required" => ["path"]
      }
    )
  end

  # Reads a file and changes nothing, so it cannot race with the tool beside it.
  @impl true
  def concurrent?, do: true

  @impl true
  def run(%{"path" => path} = args, ctx) when is_binary(path) do
    full = resolve(path, ctx)

    case File.read(full) do
      {:ok, content} -> {:ok, window(content, args["offset"], args["limit"], max_bytes(ctx))}
      {:error, reason} -> {:error, "cannot read #{full}: #{:file.format_error(reason)}"}
    end
  end

  # A non-string path (e.g. a JSON array of char codes decoding to a charlist) is rejected: it is
  # never a legitimate call, and a charlist is a valid path for File.read that would otherwise
  # sidestep the string-based workspace checks.
  def run(%{"path" => _}, _ctx), do: {:error, "'path' must be a string"}
  def run(_, _), do: {:error, "missing 'path'"}

  defp resolve(path, ctx), do: Pepe.Agent.Workspace.resolve_in_ctx(path, ctx)

  # Size the page to the running model, when the runtime told us which one that is
  # (`Pepe.Agent.Runtime` puts the head of the failover chain in tool ctx). The
  # window lookup + default is `Pepe.Agent.Compaction.window/1`, the same resolution
  # compaction itself uses.
  defp max_bytes(%{model: %Pepe.Config.Model{} = model}) do
    (Pepe.Agent.Compaction.window(model) * 4)
    |> div(10)
    |> min(@ceiling_bytes)
    |> max(@floor_bytes)
  end

  defp max_bytes(_ctx), do: @fallback_bytes

  # Slice the requested lines out of the file and keep the result under `max_bytes`.
  # A full read that fits comes back verbatim (the common case, byte-identical to the
  # old behavior); anything partial carries a note telling the model where it is and
  # how to get the rest.
  defp window(content, offset, limit, max_bytes) do
    lines = String.split(content, "\n")
    total = length(lines)

    start = if is_integer(offset) and offset > 1, do: min(offset, total), else: 1
    requested = Enum.drop(lines, start - 1)
    requested = if is_integer(limit) and limit > 0, do: Enum.take(requested, limit), else: requested

    {kept, clipped?} = cap_bytes(requested, max_bytes)
    text = Enum.join(kept, "\n")
    full_read? = start == 1 and length(kept) == total and not clipped?

    if full_read? do
      text
    else
      shown_to = start + max(length(kept) - 1, 0)

      text <>
        "\n\n[read_file: showing lines #{start}-#{shown_to} of #{total} " <>
        "(file is #{byte_size(content)} bytes). Call read_file again with " <>
        "\"offset\"/\"limit\" to read another slice.]"
    end
  end

  # Keep whole lines up to the byte budget. A first line that alone blows the budget
  # (a minified one-liner) is clipped mid-line rather than returned in full.
  defp cap_bytes([], _max_bytes), do: {[], false}

  defp cap_bytes([line | _] = lines, max_bytes) do
    if byte_size(line) > max_bytes do
      {[binary_part(line, 0, max_bytes) <> " ...(line clipped)"], true}
    else
      take_lines(lines, max_bytes)
    end
  end

  defp take_lines(lines, budget) do
    {kept, _bytes, clipped?} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {acc, bytes, _} ->
        used = bytes + byte_size(line) + 1

        if used > budget do
          {:halt, {acc, bytes, true}}
        else
          {:cont, {[line | acc], used, false}}
        end
      end)

    {Enum.reverse(kept), clipped?}
  end
end
