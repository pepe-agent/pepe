defmodule Pepe.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Pepe.Tools.ReadFile

  # No agent in ctx, so absolute paths resolve as-is (Workspace.resolve_in_ctx), and
  # no model, so the cap is the fixed 30KB fallback.
  @ctx %{}

  defp ctx_with_window(tokens),
    do: %{model: %Pepe.Config.Model{name: "m", context_window: tokens}}

  defp tmp_file(content) do
    path = Path.join(System.tmp_dir!(), "read_file_test_#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a small file comes back verbatim, no note" do
    path = tmp_file("hello\nworld")
    assert {:ok, "hello\nworld"} = ReadFile.run(%{"path" => path}, @ctx)
  end

  test "a large file is capped with a note instead of entering the history in full" do
    # 5_000 lines x ~12 bytes = ~60KB, past the 30KB cap.
    content = Enum.map_join(1..5_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path}, @ctx)

    assert byte_size(out) < 32_000
    assert out =~ "line-1-xxxx"
    assert out =~ ~r/showing lines 1-\d+ of 5000/
    assert out =~ "\"offset\"/\"limit\""
    refute out =~ "line-5000-xxxx"
  end

  test "offset/limit page through a file, with a note saying where the slice is" do
    content = Enum.map_join(1..100, "\n", &"line-#{&1}")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path, "offset" => 41, "limit" => 3}, @ctx)

    assert out =~ "line-41\nline-42\nline-43"
    refute out =~ "line-40\n"
    refute out =~ "line-44"
    assert out =~ "showing lines 41-43 of 100"
  end

  test "a single line bigger than the cap is clipped mid-line" do
    path = tmp_file(String.duplicate("a", 60_000))

    {:ok, out} = ReadFile.run(%{"path" => path}, @ctx)

    assert byte_size(out) < 32_000
    assert out =~ "(line clipped)"
    assert out =~ "showing lines 1-1 of 1"
  end

  test "clipping a huge multi-byte line never cuts mid-codepoint and stays under the cap" do
    # A leading ASCII byte plus a 4-byte emoji repeated: the naive byte-count cut
    # point almost never lands on a codepoint boundary, so this fails loudly on a
    # plain binary_part/3 clip.
    path = tmp_file("a" <> String.duplicate("🎉", 20_000))

    {:ok, out} = ReadFile.run(%{"path" => path}, @ctx)

    assert String.valid?(out)
    assert byte_size(out) <= 30_000
    assert out =~ "(line clipped)"
  end

  test "a large context window gets a proportionally bigger page" do
    # ~60KB file: past the 30KB no-model fallback, but 10% of a 200K-token window at
    # ~4 bytes/token is an 80KB page, so the whole file comes back verbatim in one call.
    content = Enum.map_join(1..5_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path}, ctx_with_window(200_000))

    assert out == content
    refute out =~ "showing lines"
  end

  test "a small context window still gets the 32KB floor, not a tiny page" do
    # 10% of an 8K window would be a useless ~3.2KB page; the floor keeps it at 32KB,
    # so the page is bigger than the 30KB no-model fallback, not smaller.
    content = Enum.map_join(1..5_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path}, ctx_with_window(8_000))

    assert byte_size(out) > 30_000
    assert byte_size(out) < 33_000
    assert out =~ ~r/showing lines 1-\d+ of 5000/
  end

  test "a huge context window is capped at the 128KB ceiling" do
    # ~200KB file on a 5M-token window: 10% would be 2MB, the ceiling holds it at 128KB.
    content = Enum.map_join(1..15_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path}, ctx_with_window(5_000_000))

    assert byte_size(out) > 120_000
    assert byte_size(out) < 129_000
    assert out =~ ~r/showing lines 1-\d+ of 15000/
  end

  test "a model without a declared context window uses compaction's default window" do
    # Compaction.window/1 falls back to 128K tokens -> ~51KB page: a ~40KB file fits.
    content = Enum.map_join(1..3_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    assert {:ok, ^content} = ReadFile.run(%{"path" => path}, ctx_with_window(nil))
  end

  test "no model in ctx falls back to the fixed 30KB cap" do
    content = Enum.map_join(1..5_000, "\n", &"line-#{&1}-xxxx")
    path = tmp_file(content)

    {:ok, out} = ReadFile.run(%{"path" => path}, @ctx)

    assert byte_size(out) < 31_000
    assert out =~ "showing lines"
  end

  test "non-integer offset/limit are ignored rather than crashing the tool" do
    path = tmp_file("a\nb")
    assert {:ok, "a\nb"} = ReadFile.run(%{"path" => path, "offset" => "x", "limit" => nil}, @ctx)
  end

  test "a missing file is a readable error" do
    assert {:error, msg} = ReadFile.run(%{"path" => "/nonexistent/nope.txt"}, @ctx)
    assert msg =~ "cannot read"
  end
end
