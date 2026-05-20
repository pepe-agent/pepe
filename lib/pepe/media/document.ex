defmodule Pepe.Media.Document do
  @moduledoc """
  Turn a document into text at the door, so the agent is handed a message rather than a
  puzzle.

  A file sent in a chat is not a research task, it is a message with something attached. The
  agent *can* work it out on its own, and until now it had to: identify the type, pick a
  library, install it, write a script, run it. That works and it is expensive. It costs
  several turns, it needs the agent to hold `bash`, which a client-facing agent must never
  hold, and it comes out differently every time.

  So the text exists before routing does. A PDF captioned "summarise this" reads as one
  message, a document sent to an agent with no shell still works, and none of it depends on
  the model being clever that afternoon.

  ## Three tiers, and they cost wildly different things

    * **Text.** `.txt`, `.md`, `.csv`, `.json`, `.log`, and the rest. Read the file. There is
      no library, no dependency, and nothing to install, and it is faintly embarrassing that
      this ever went the long way round.

    * **Office files.** `.docx`, `.xlsx`, `.pptx` are ZIP archives full of XML, and OTP ships
      an unzipper. So they cost nothing either: no Python, no system package, no bytes on the
      image. This is the part nobody expects to be free.

    * **PDF.** The one that genuinely needs a library. `pdftotext` is used when the machine
      has it, and when it does not, this returns `:unavailable` and the agent falls back to
      working it out for itself, exactly as it does today, installing what it needs once.

  A `.zip` is deliberately **not** handled. It is a box, not a document: there is no "the
  text" in it, and unpacking whatever a stranger sends you is how you accept a decompression
  bomb and a path-traversal in the same gesture. The office formats are safe precisely
  because they are not general: one entry is read, by name, into memory, and nothing is ever
  written to disk.
  """

  require Logger

  # Enough of a document for a model to answer about, and not so much that one attachment
  # eats the context window. The file stays on disk, so an agent that needs the rest reads it.
  @max_chars 30_000

  # A ZIP entry that expands to more than this is not a document, it is an attack.
  @max_unzipped 20_000_000

  @text ~w(.txt .text .md .markdown .csv .tsv .json .xml .html .htm .log .yml .yaml .toml .ini .rst .srt .vtt .sql .sh .ex .exs .py .js .ts)

  @doc """
  The text of the document at `path`, or `:unavailable` when we have no way to read it and
  the agent should fall back to working it out.

  Never raises. A file that is corrupt, encrypted, or simply not what its name claims is
  `:unavailable`, and the agent gets the file, which is what used to happen for everything.
  """
  @spec extract(String.t()) :: {:ok, String.t()} | :unavailable
  def extract(path) do
    case Path.extname(path) |> String.downcase() do
      ext when ext in @text -> read_text(path)
      ".docx" -> docx(path)
      ".xlsx" -> xlsx(path)
      ".pptx" -> pptx(path)
      ".pdf" -> pdf(path)
      _ -> :unavailable
    end
  rescue
    e ->
      Logger.warning("[media] could not read #{Path.basename(path)}: #{Exception.message(e)}")
      :unavailable
  end

  @doc "Whether we can read this kind of file at the door at all (used to explain ourselves)."
  @spec readable?(String.t()) :: boolean()
  def readable?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @text or ext in ~w(.docx .xlsx .pptx) or (ext == ".pdf" and pdftotext())
  end

  ###
  ### plain text
  ###

  defp read_text(path) do
    case File.read(path) do
      {:ok, body} -> present(body)
      {:error, _} -> :unavailable
    end
  end

  ###
  ### office files: a ZIP of XML, and OTP already unzips
  ###

  # Word keeps the document in one entry. Paragraphs are `<w:p>`, so they become the
  # newlines, and everything else is markup nobody needs to read.
  defp docx(path) do
    with {:ok, xml} <- entry(path, ~c"word/document.xml") do
      xml
      |> String.replace(~r{</w:p>}, "\n")
      |> strip_tags()
      |> present()
    end
  end

  # Slides are one entry each, in an order the archive does not promise, so they are sorted
  # by their number rather than by however they happen to be stored.
  defp pptx(path) do
    with {:ok, entries} <- entries(path, ~r{^ppt/slides/slide\d+\.xml$}) do
      entries
      |> Enum.sort_by(fn {name, _} -> slide_number(name) end)
      |> Enum.map_join("\n\n", fn {_, xml} ->
        xml |> String.replace(~r{</a:p>}, "\n") |> strip_tags()
      end)
      |> present()
    end
  end

  defp slide_number(name) do
    case Regex.run(~r/slide(\d+)\.xml/, to_string(name)) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  # A spreadsheet is the one where naively stripping the tags would be worse than useless: it
  # would hand back a wall of words with the numbers missing and the rows collapsed, which
  # reads plausible and is wrong. So the cells are actually read.
  #
  # Excel stores repeated strings once, in a shared table, and a cell of type "s" holds an
  # index into it. Everything else holds its own value.
  defp xlsx(path) do
    with {:ok, sheets} <- entries(path, ~r{^xl/worksheets/sheet\d+\.xml$}) do
      shared = shared_strings(path)

      sheets
      |> Enum.sort_by(fn {name, _} -> sheet_number(name) end)
      |> Enum.map_join("\n\n", fn {_, xml} -> sheet_rows(xml, shared) end)
      |> present()
    end
  end

  defp sheet_number(name) do
    case Regex.run(~r/sheet(\d+)\.xml/, to_string(name)) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp shared_strings(path) do
    case entry(path, ~c"xl/sharedStrings.xml") do
      {:ok, xml} ->
        ~r{<si>(.*?)</si>}s
        |> Regex.scan(xml, capture: :all_but_first)
        |> Enum.map(fn [si] -> si |> strip_tags() |> String.trim() end)

      _ ->
        []
    end
  end

  # One row per line, cells separated by tabs, which is a spreadsheet's own shape and reads
  # as one to both a human and a model.
  defp sheet_rows(xml, shared) do
    ~r{<row[^>]*>(.*?)</row>}s
    |> Regex.scan(xml, capture: :all_but_first)
    |> Enum.map_join("\n", fn [row] -> row |> cells(shared) |> Enum.join("\t") end)
  end

  defp cells(row, shared) do
    ~r{<c([^>]*)>(.*?)</c>}s
    |> Regex.scan(row, capture: :all_but_first)
    |> Enum.map(fn [attrs, body] -> cell(attrs, body, shared) end)
  end

  defp cell(attrs, body, shared) do
    value =
      case Regex.run(~r{<v>(.*?)</v>}s, body, capture: :all_but_first) do
        [v] -> v
        _ -> body |> strip_tags() |> String.trim()
      end

    if String.contains?(attrs, ~s(t="s")) do
      Enum.at(shared, int(value), "")
    else
      unescape(value)
    end
  end

  defp int(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      :error -> -1
    end
  end

  ###
  ### PDF: the one that needs something installed
  ###

  defp pdf(path) do
    if pdftotext() do
      case System.cmd("pdftotext", ["-layout", "-q", path, "-"], stderr_to_stdout: false) do
        {out, 0} -> present(out)
        _ -> :unavailable
      end
    else
      # Nothing on this machine can read it, so the agent gets the file and works it out with
      # the tools it has, installing what it needs once. Slower and dearer, and it is the
      # fallback rather than the way in.
      :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp pdftotext, do: System.find_executable("pdftotext") != nil

  ###
  ### the zip, read without ever unpacking it
  ###

  # One named entry, into memory. Never `:zip.unzip` to disk: the names inside an archive are
  # whatever the sender wrote, including `../../etc/anything`.
  #
  # The size is checked against the central directory *before* anything is inflated, because
  # `:zip.extract(:memory)` does not stream - it hands back the fully inflated binary, so a
  # cap on the *result* is a cap applied after the damage. A 20 MB archive whose entries
  # declare gigabytes of output is refused here rather than allocated and then trimmed. That
  # is the whole difference between a size cap and a decompression-bomb defence.
  defp entry(path, name) do
    with :ok <- within_budget?(path, &(&1 == name)),
         {:ok, [{^name, body}]} <-
           :zip.extract(String.to_charlist(path), [{:file_list, [name]}, :memory]) do
      {:ok, body}
    else
      _ -> :unavailable
    end
  end

  # Only the entries matching `pattern` are extracted, by name. `:zip.extract(:memory)` with no
  # `:file_list` inflates EVERY entry, so a `.xlsx`/`.pptx` carrying one tiny legit sheet (which
  # passes the budget) plus a huge non-matching entry (`xl/media/bomb.bin`) would still be fully
  # inflated and OOM the node. Extracting only the matching names, after budgeting those same
  # names, means a non-matching bomb is never inflated at all.
  defp entries(path, pattern) do
    with {:ok, names} <- matching_names(path, pattern),
         :ok <- within_budget?(path, &(to_string(&1) =~ pattern)),
         {:ok, list} <- :zip.extract(String.to_charlist(path), [{:file_list, names}, :memory]) do
      matching(list)
    else
      _ -> :unavailable
    end
  end

  # The names (charlists, as `:file_list` wants) of the entries matching `pattern`, read from the
  # central directory without inflating anything.
  defp matching_names(path, pattern) do
    with {:ok, list} <- :zip.list_dir(String.to_charlist(path)),
         [_ | _] = names <-
           for({:zip_file, name, _info, _, _, _} <- list, to_string(name) =~ pattern, do: name) do
      {:ok, names}
    else
      _ -> :unavailable
    end
  end

  defp matching([]), do: :unavailable
  defp matching(found), do: {:ok, found}

  # Sum the *declared* uncompressed sizes of the entries we are about to read (from the zip's
  # central directory, which `:zip.list_dir` reads without inflating a single byte) and refuse
  # if they exceed the cap. This is what stops a deflate bomb: the archive says up front how
  # big it claims to be, and we never inflate an entry we would have to throw most of away.
  defp within_budget?(path, keep?) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, list} ->
        total =
          list
          |> Enum.flat_map(fn
            {:zip_file, name, info, _, _, _} -> [{name, info}]
            _ -> []
          end)
          |> Enum.filter(fn {name, _} -> keep?.(name) end)
          |> Enum.map(fn {_, info} -> declared_size(info) end)
          |> Enum.sum()

        if total <= @max_unzipped, do: :ok, else: :unavailable

      _ ->
        :unavailable
    end
  end

  # The uncompressed size is the first field of the file_info record the central directory
  # carries. A missing or bogus value is treated as over-budget rather than trusted as zero.
  defp declared_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _}) when is_integer(size) and size >= 0,
    do: size

  defp declared_size(_), do: @max_unzipped + 1

  ###
  ### text out
  ###

  defp strip_tags(xml) do
    xml
    |> String.replace(~r{<[^>]*>}, "")
    |> unescape()
  end

  defp unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#10;", "\n")
  end

  # Nothing in it is not something to hand a model: an empty message produces a confused
  # reply, and the agent would have done better with the file.
  defp present(text) do
    text = text |> collapse() |> String.trim()

    cond do
      text == "" -> :unavailable
      String.length(text) > @max_chars -> {:ok, String.slice(text, 0, @max_chars)}
      true -> {:ok, text}
    end
  end

  defp collapse(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  @doc "How much of a document is handed over before the rest is left on disk."
  def max_chars, do: @max_chars
end
