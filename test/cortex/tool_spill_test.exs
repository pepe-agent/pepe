defmodule Cortex.ToolSpillTest do
  use ExUnit.Case, async: false

  alias Cortex.Config.Agent

  setup do
    home = Path.join(System.tmp_dir!(), "cortex_spill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("CORTEX_HOME")
    System.put_env("CORTEX_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("CORTEX_HOME", prev), else: System.delete_env("CORTEX_HOME")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp call(cmd),
    do: %{"function" => %{"name" => "bash", "arguments" => Jason.encode!(%{"command" => cmd})}}

  test "huge tool output is spilled to a workspace file with an inline preview" do
    ctx = %{agent: %Agent{name: "spiller"}, cwd: System.tmp_dir!()}
    # ~20KB of output — past the spill threshold but under bash's own 30KB cap, so
    # this exercises the spill path specifically (not bash's separate truncation).
    out = Cortex.Tools.execute(call("yes 0123456789abcdef | head -c 20000"), ctx)

    assert out =~ "output truncated"
    assert [path] = Regex.run(~r/saved to (\S+)/, out, capture: :all_but_first)
    assert File.exists?(path)
    assert File.stat!(path).size >= 20_000
    # Preview stays small.
    assert byte_size(out) < 3_000
  end

  test "small output passes through untouched" do
    ctx = %{agent: %Agent{name: "spiller"}, cwd: System.tmp_dir!()}
    out = Cortex.Tools.execute(call("echo small"), ctx)
    assert String.trim(out) =~ "small"
    refute out =~ "truncated"
  end
end
