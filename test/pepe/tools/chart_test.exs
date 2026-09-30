defmodule Pepe.Tools.ChartTest do
  use ExUnit.Case, async: false

  alias Pepe.Tools.Chart

  setup do
    dir = Path.join(System.tmp_dir!(), "pepe_chart_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, ctx: %{cwd: dir, workspace: dir}, dir: dir}
  end

  defp args(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "bar",
        "title" => "Orders per day",
        "labels" => ["Mon", "Tue", "Wed"],
        "series" => [%{"name" => "Orders", "values" => [4, 9, 6]}],
        "send" => false
      },
      overrides
    )
  end

  test "is a registered built-in tool" do
    assert "chart" in Enum.map(Pepe.Tools.all(), & &1.name())
  end

  describe "validation" do
    test "rejects an unknown chart type" do
      assert {:error, msg} = Chart.validate(args(%{"type" => "radar"}))
      assert msg =~ "bar, line, pie"
    end

    test "rejects a series whose length does not match the labels" do
      assert {:error, msg} = Chart.validate(args(%{"series" => [%{"name" => "Orders", "values" => [1, 2]}]}))
      assert msg =~ "2 values for 3 labels"
    end

    test "rejects a value that is not a number, accepts a numeric string" do
      assert {:error, _} = Chart.validate(args(%{"series" => [%{"name" => "x", "values" => [1, "many", 3]}]}))
      assert {:ok, %{series: [%{values: [1.0, 2, 3]}]}} = Chart.validate(args(%{"series" => [%{"name" => "x", "values" => ["1", 2, 3]}]}))
    end

    test "a pie takes exactly one series" do
      two = [%{"name" => "a", "values" => [1, 2, 3]}, %{"name" => "b", "values" => [1, 2, 3]}]
      assert {:error, msg} = Chart.validate(args(%{"type" => "pie", "series" => two}))
      assert msg =~ "exactly one series"
    end

    test "caps the number of points and series" do
      many = Enum.map(1..61, &to_string/1)
      assert {:error, _} = Chart.validate(args(%{"labels" => many, "series" => [%{"name" => "x", "values" => Enum.to_list(1..61)}]}))

      seven = for i <- 1..7, do: %{"name" => "s#{i}", "values" => [1, 2, 3]}
      assert {:error, _} = Chart.validate(args(%{"series" => seven}))
    end
  end

  test "saving without sending writes the image into the workspace", %{ctx: ctx, dir: dir} do
    assert {:ok, message} = Chart.run(args(), ctx)

    [file] = Path.wildcard(Path.join([dir, "charts", "*"]))
    assert Path.extname(file) in [".png", ".svg"]
    assert message =~ file

    # Without a converter the result must say it fell back to SVG, so the agent does not promise a PNG.
    if Path.extname(file) == ".svg", do: assert(message =~ "SVG")
  end

  test "a conversation-less run saves instead of trying to send", %{ctx: ctx} do
    assert {:ok, message} = Chart.run(Map.delete(args(), "send"), ctx)
    assert message =~ "saved"
  end
end
