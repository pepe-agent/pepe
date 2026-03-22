defmodule Pepe.Skills.SentinelCodeTest do
  use ExUnit.Case, async: true

  alias Pepe.Skills.Sentinel

  defp cats(scan), do: scan.findings |> Enum.map(& &1.category) |> Enum.uniq()

  test "flags dangerous Elixir calls via the AST, with categories and lines" do
    src = """
    defmodule Evil do
      def run(x) do
        System.cmd("sh", ["-c", x])
        File.rm_rf!("/tmp/x")
        Code.eval_string(x)
        apply(String, :to_atom, [x])
        :erlang.binary_to_term(x)
      end
    end
    """

    scan = Sentinel.scan_code(src, "evil.exs")

    assert scan.verdict == :danger
    assert "shell-exec" in cats(scan)
    assert "destructive-fs" in cats(scan)
    assert "dynamic-eval" in cats(scan)
    assert "unsafe-deserialize" in cats(scan)
    assert "dynamic-dispatch" in cats(scan)

    # findings carry the file label and a real line number
    shell = Enum.find(scan.findings, &(&1.category == "shell-exec"))
    assert shell.file == "evil.exs"
    assert shell.line == 3
  end

  test "sees aliased and erlang forms the same way" do
    src = """
    defmodule A do
      alias System, as: Sys
      def go, do: :os.cmd(~c"whoami")
    end
    """

    scan = Sentinel.scan_code(src)
    assert scan.verdict == :danger
    assert "shell-exec" in cats(scan)
  end

  test "does not trip over dangerous words that are only in comments or strings" do
    src = """
    defmodule Fine do
      # this does not actually call System.cmd or Code.eval_string
      def note, do: "System.cmd is dangerous"
    end
    """

    scan = Sentinel.scan_code(src)
    assert scan.verdict == :safe
    assert scan.findings == []
  end

  test "network and env reads are cautions, not blockers" do
    src = """
    defmodule Net do
      def go, do: Req.post("https://api.example", body: System.get_env("TOKEN"))
    end
    """

    scan = Sentinel.scan_code(src)
    assert scan.verdict == :caution
    assert "network" in cats(scan)
    assert "reads-env" in cats(scan)
  end

  test "flags reading secrets or Pepe's own config via string paths" do
    src = ~S"""
    defmodule Steal do
      def go, do: File.read(Path.expand("~/.ssh/id_rsa"))
    end
    """

    scan = Sentinel.scan_code(src)
    assert scan.verdict == :danger
    assert "reads-secrets" in cats(scan)
  end

  test "unparseable source falls back to the text pass instead of crashing" do
    scan = Sentinel.scan_code("def broken( do :erlang.binary_to_term")
    assert is_map(scan)
    assert scan.verdict in [:safe, :caution, :danger]
  end
end
