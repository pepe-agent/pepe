defmodule Pepe.Media.DocumentTest do
  @moduledoc """
  A document becomes text at the door, so the agent is handed a message rather than a puzzle.

  The spreadsheet is the case worth watching. Stripping the tags out of an `.xlsx` produces
  something that *looks* like an answer, a wall of the words that were in it, with the numbers
  gone and the rows collapsed into each other. A model reading that will answer confidently
  and wrongly, and nobody will know. So the cells are actually read.
  """
  use ExUnit.Case, async: true

  alias Pepe.Media.Document

  setup do
    dir = Path.join(System.tmp_dir!(), "pepe_doc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  # A real Office file: a ZIP of XML entries, which is what makes these free to read.
  defp zip!(dir, name, entries) do
    path = Path.join(dir, name)

    {:ok, _} =
      :zip.create(
        String.to_charlist(path),
        Enum.map(entries, fn {n, body} -> {String.to_charlist(n), body} end)
      )

    path
  end

  describe "text, which costs nothing and never should have gone the long way round" do
    test "a .txt is simply read", %{dir: dir} do
      path = write(dir, "notes.txt", "the meeting is at four")

      assert {:ok, "the meeting is at four"} = Document.extract(path)
    end

    test "so is a .csv, a .json, a .md and a log", %{dir: dir} do
      assert {:ok, text} = Document.extract(write(dir, "rows.csv", "name,total\nacme,42"))
      assert text =~ "acme,42"

      assert {:ok, text} = Document.extract(write(dir, "data.json", ~s({"total": 42})))
      assert text =~ "42"

      assert {:ok, text} = Document.extract(write(dir, "readme.md", "# Title\n\nBody."))
      assert text =~ "Title"

      assert {:ok, text} = Document.extract(write(dir, "app.log", "boot ok"))
      assert text =~ "boot ok"
    end

    test "an empty file is not a message", %{dir: dir} do
      # Handing a model an empty document produces a confused reply about nothing. The agent
      # gets the file instead, and can say what is actually wrong with it.
      assert Document.extract(write(dir, "empty.txt", "   \n\n  ")) == :unavailable
    end
  end

  describe "office files, which are ZIPs of XML and therefore also free" do
    test "a .docx gives its paragraphs, one per line", %{dir: dir} do
      xml = """
      <?xml version="1.0"?>
      <w:document><w:body>
        <w:p><w:r><w:t>Quarterly report</w:t></w:r></w:p>
        <w:p><w:r><w:t>Revenue rose by </w:t></w:r><w:r><w:t>12%</w:t></w:r></w:p>
      </w:body></w:document>
      """

      path = zip!(dir, "report.docx", [{"word/document.xml", xml}])

      assert {:ok, text} = Document.extract(path)
      assert text =~ "Quarterly report"
      # A run split across two elements is still one sentence, which is how Word stores a
      # sentence that had a word bolded in the middle of it.
      assert text =~ "Revenue rose by 12%"
    end

    test "a .pptx gives its slides, in the order they are shown", %{dir: dir} do
      slide = fn t -> "<p:sld><a:p><a:r><a:t>#{t}</a:t></a:r></a:p></p:sld>" end

      # Deliberately stored out of order: a ZIP promises nothing about entry order, and a deck
      # read backwards is a deck that says the opposite of what it says.
      path =
        zip!(dir, "deck.pptx", [
          {"ppt/slides/slide2.xml", slide.("Then the results")},
          {"ppt/slides/slide1.xml", slide.("First the plan")}
        ])

      assert {:ok, text} = Document.extract(path)

      [first, second] = String.split(text, "\n\n", trim: true) |> Enum.map(&String.trim/1)
      assert first =~ "First the plan"
      assert second =~ "Then the results"
    end

    test "a .xlsx gives the cells, not a wall of words with the numbers missing", %{dir: dir} do
      shared = """
      <sst><si><t>product</t></si><si><t>units</t></si><si><t>widget</t></si></sst>
      """

      sheet = """
      <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1250</v></c></row>
      </sheetData></worksheet>
      """

      path =
        zip!(dir, "sales.xlsx", [
          {"xl/sharedStrings.xml", shared},
          {"xl/worksheets/sheet1.xml", sheet}
        ])

      assert {:ok, text} = Document.extract(path)

      # A spreadsheet's shape is rows and columns, and it arrives as rows and columns.
      assert text == "product\tunits\nwidget\t1250"

      # This is the whole point. Excel keeps repeated strings in a shared table and a cell
      # holds an *index* into it, so a naive tag-strip yields "0 1 2 1250": the words gone,
      # the indices masquerading as data, and the one real number sitting among them. The
      # model would answer that with total confidence.
      refute text =~ ~r/\b0\b/
      assert text =~ "1250"
    end

    test "a file that claims to be a .docx and is not is not readable", %{dir: dir} do
      # Corrupt, encrypted, or simply mislabelled. It falls to the agent, which is what used
      # to happen for everything and can at least say what is wrong with it.
      assert Document.extract(write(dir, "broken.docx", "this is not a zip")) == :unavailable
    end
  end

  describe "what we deliberately do not open" do
    test "a .zip is a box, not a document", %{dir: dir} do
      path = zip!(dir, "stuff.zip", [{"a.txt", "hello"}])

      # There is no "the text" of an archive, and unpacking whatever a stranger sends you is
      # how you accept a decompression bomb and a path traversal in one gesture. The agent
      # opens it, at the permission gate, having decided to.
      assert Document.extract(path) == :unavailable
    end

    test "an image is not a document either", %{dir: dir} do
      assert Document.extract(write(dir, "photo.jpg", "\xFF\xD8\xFF")) == :unavailable
    end
  end

  describe "size" do
    test "a long document is handed over in part, and the file stays on disk", %{dir: dir} do
      long = String.duplicate("word ", 20_000)
      path = write(dir, "book.txt", long)

      assert {:ok, text} = Document.extract(path)

      # One attachment must not eat the context window. The agent is told where the file is,
      # so if it needs the rest it reads the rest.
      assert String.length(text) == Document.max_chars()
    end
  end
end
