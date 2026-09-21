defmodule Pepe.Checkpoints.ReportTest do
  @moduledoc """
  The words every surface shares for a rewind. Pure text in, text out: what a person is told
  about the conversation, and about each group of files, must be the same on Telegram, the
  console, the dashboard and the editor because it comes from here.
  """
  use ExUnit.Case, async: true

  alias Pepe.Checkpoints.Report

  @root "/work/agent"

  defp report(overrides \\ []) do
    Enum.into(overrides, %{restored: [], removed: [], skipped: [], untracked: [], partial?: false})
  end

  describe "parse_args/1" do
    test "a bare command is one turn, both" do
      assert Report.parse_args("") == {:ok, 1, :both}
      assert Report.parse_args("   ") == {:ok, 1, :both}
    end

    test "a count, with or without a mode, in any order and case" do
      assert Report.parse_args("3") == {:ok, 3, :both}
      assert Report.parse_args("3 chat") == {:ok, 3, :chat}
      assert Report.parse_args("chat 3") == {:ok, 3, :chat}
      assert Report.parse_args("2 FILES") == {:ok, 2, :files}
      assert Report.parse_args("2 both") == {:ok, 2, :both}
    end

    test "a mode alone means one turn" do
      assert Report.parse_args("files") == {:ok, 1, :files}
      assert Report.parse_args("chat") == {:ok, 1, :chat}
    end

    test "anything else is refused, and nothing is guessed" do
      assert Report.parse_args("banana") == :error
      assert Report.parse_args("0") == :error
      assert Report.parse_args("-1") == :error
      assert Report.parse_args("2 turns") == :error
      assert Report.parse_args("chat files") == :error
      assert Report.parse_args("2 chat 3") == :error
    end
  end

  describe "summary/2" do
    test "names the turns that went and the files that came back" do
      text = Report.summary(%{dropped: 2, files: report(restored: ["#{@root}/notes.md"]), roots: [@root]}, requested: 2)

      assert text =~ "Rewound 2 turns."
      assert text =~ "Put back 1 file: notes.md."
    end

    test "says when the whole conversation was less than what was asked" do
      assert Report.summary(%{dropped: 1, files: nil}, requested: 5) =~ "Rewound 1 turn. That was the whole conversation."
    end

    test "says plainly when there was nothing to rewind" do
      assert Report.summary(%{dropped: 0, files: nil}, requested: 1) == "Nothing to rewind yet."
    end

    test "chat only says how many files were left, and how to put them back" do
      text = Report.summary(%{dropped: 1, files: nil, kept: 2}, requested: 1, mode: :chat)

      assert text =~ "The 2 files those turns changed were left as they are."
      assert text =~ ~s(Leave out "chat" to put files back too.)
    end

    test "files only says the conversation is unchanged, or that nothing was put back" do
      done = Report.summary(%{dropped: 0, files: report(restored: ["#{@root}/a"])}, requested: 2, mode: :files, roots: [@root])
      assert done =~ "Put files back for the last 2 turns. The conversation is unchanged."

      nothing = Report.summary(%{dropped: 0, files: report()}, requested: 1, mode: :files)
      assert nothing =~ "Nothing was put back. The conversation is unchanged."
    end
  end

  describe "file_lines/2" do
    test "nothing to report says no changes were recorded, instead of staying silent" do
      assert Report.file_lines(report(), []) == ["No file changes were recorded for those turns."]
      assert Report.file_lines(nil, []) == []
    end

    test "restored and removed are separate lines, with paths relative to the root" do
      lines = Report.file_lines(report(restored: ["#{@root}/a.md", "#{@root}/b/c.md"], removed: ["#{@root}/new.md"]), roots: [@root])

      assert lines == [
               "Put back 2 files: a.md, b/c.md.",
               "Removed 1 file those turns created: new.md."
             ]
    end

    test "a long list is cut with a count of the rest" do
      paths = for n <- 1..8, do: "#{@root}/f#{n}.md"
      [line] = Report.file_lines(report(restored: paths), roots: [@root])

      assert line =~ "f1.md, f2.md, f3.md, f4.md, f5.md +3"
      refute line =~ "f6.md"
    end

    test "a path outside every root is shown whole" do
      [line] = Report.file_lines(report(restored: ["/elsewhere/x"]), roots: [@root])
      assert line =~ "/elsewhere/x"
    end

    test "each reason a file was left alone gets its own honest line" do
      skipped = [
        %{path: "#{@root}/a", reason: :changed_since},
        %{path: "#{@root}/b", reason: :too_large},
        %{path: "#{@root}/c", reason: :expired},
        %{path: "#{@root}/d", reason: :unwritable}
      ]

      lines = Report.file_lines(report(skipped: skipped), roots: [@root])

      assert "Left 1 file alone because it changed afterwards: a." in lines
      assert "No copy was kept of 1 file (too large): b." in lines
      assert "The saved copy of 1 file has expired: c." in lines
      assert "Could not put back 1 file: d." in lines
    end

    test "credentials and out-of-bounds files are named as never covered" do
      untracked = [%{path: "#{@root}/.env", reason: :sensitive}, %{path: "/etc/hosts", reason: :outside}]
      lines = Report.file_lines(report(untracked: untracked), roots: [@root])

      assert Enum.any?(lines, &(&1 =~ "looks like a credential" and &1 =~ ".env"))
      assert Enum.any?(lines, &(&1 =~ "outside the folders a rewind may touch" and &1 =~ "/etc/hosts"))
    end

    test "turns whose files were already put back say so instead of claiming nothing was recorded" do
      assert Report.file_lines(Map.put(report(), :already, 1), []) == ["The files of those turns were already put back."]
    end

    test "turns older than the file history, cleaned-up records and shell overflow are said" do
      lines = Report.file_lines(report(partial?: true) |> Map.merge(%{unreached: 2, expired: 1}), [])

      assert Enum.any?(lines, &(&1 =~ "changed more files than can be recorded"))
      assert Enum.any?(lines, &(&1 =~ "2 of those turns are older than the file history"))
      assert Enum.any?(lines, &(&1 =~ "1 recorded change had already been cleaned up."))
    end
  end

  describe "turn_list/1" do
    test "lists newest first with a file count only where there is one" do
      text =
        Report.turn_list([
          %{n: 1, preview: "fix the notes", files: 2},
          %{n: 2, preview: "hello", files: 0},
          %{n: 3, preview: "older", files: nil},
          %{n: 4, preview: "", files: nil}
        ])

      assert text =~ "Recent turns, newest first:"
      assert text =~ "1. fix the notes (2 files)"
      assert text =~ "\n2. hello\n"
      assert text =~ "\n3. older\n"
      assert text =~ "4. (no text)"
    end

    test "carries the usage so the next step is in reach" do
      text = Report.turn_list([%{n: 1, preview: "x", files: 0}])

      assert text =~ "/rewind N goes back N turns"
      assert text =~ "/rewind N chat"
      assert text =~ "/rewind N files"
    end

    test "an empty conversation has nothing to list" do
      assert Report.turn_list([]) == "Nothing to rewind yet."
    end
  end

  describe "agent_note/2 (what the model is told)" do
    test "is plain English, wrapped so the model reads it as a system note" do
      note =
        Report.agent_note(report(restored: ["/w/a.md"], removed: ["/w/b.md"], skipped: [%{path: "/w/c.md", reason: :changed_since}]), 2)

      assert note =~ "<system-reminder>"
      assert note =~ "last 2 turn(s)"
      assert note =~ "Restored to how they were before those turns: /w/a.md"
      assert note =~ "Removed (those turns had created them): /w/b.md"
      assert note =~ "Left as they are (changed afterwards or not copied): /w/c.md"
      assert note =~ "Do not assume those changes exist."
    end
  end

  describe "empty?/1" do
    test "only a report with nothing in it at all is empty" do
      assert Report.empty?(nil)
      assert Report.empty?(report())
      refute Report.empty?(report(restored: ["a"]))
      refute Report.empty?(report(partial?: true))
      refute Report.empty?(Map.put(report(), :unreached, 1))
      refute Report.empty?(Map.put(report(), :already, 1))
    end
  end
end
