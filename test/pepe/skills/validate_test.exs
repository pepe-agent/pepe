defmodule Pepe.Skills.ValidateTest do
  use ExUnit.Case, async: false

  alias Pepe.Skills.Validate

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_skill_validate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "skills"))
    previous = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("PEPE_HOME", previous), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    %{home: home}
  end

  defp package(home, dir_name, header, body \\ "Use it when asked.\n") do
    dir = Path.join([home, "skills", dir_name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n#{header}\n---\n\n#{body}")
    dir
  end

  defp rules(report), do: Enum.map(report.findings, & &1.rule)

  defp severity(report, rule), do: Enum.find_value(report.findings, &(&1.rule == rule && &1.severity))

  test "a well-formed skill directory is valid", %{home: home} do
    dir = package(home, "pdf-processing", "name: pdf-processing\ndescription: Extracts text from PDFs. Use when the user sends a PDF.")

    assert {:ok, report} = Validate.run(dir)
    assert report.valid?
    assert report.errors == 0
    assert report.name == "pdf-processing"
  end

  test "a skill with no header at all is an error", %{home: home} do
    dir = Path.join([home, "skills", "plain"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "Use when something.\n")

    assert {:ok, report} = Validate.run(dir)
    refute report.valid?
    assert severity(report, :header_missing) == :error
  end

  test "a header fence that is not a YAML mapping is reported as invalid, not as missing", %{home: home} do
    dir = Path.join([home, "skills", "broken"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\n- just\n- a list\n---\n\nbody\n")

    assert {:ok, report} = Validate.run(dir)
    assert severity(report, :header_invalid) == :error
  end

  describe "name" do
    test "uppercase, a leading hyphen and consecutive hyphens are errors", %{home: home} do
      for bad <- ["PDF-Processing", "-pdf", "pdf-", "pdf--processing", "pdf processing"] do
        dir = package(home, "some-dir", "name: #{inspect(bad)}\ndescription: Use when needed.")
        {:ok, report} = Validate.run(dir)
        assert severity(report, :name_format) == :error, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "an underscore is accepted by Pepe but flagged as not portable", %{home: home} do
      dir = package(home, "read_pdf", "name: read_pdf\ndescription: Use when reading a PDF.")

      {:ok, report} = Validate.run(dir)
      assert report.valid?
      assert severity(report, :name_portable) == :warning
    end

    test "a name longer than 64 characters is an error", %{home: home} do
      long = String.duplicate("a", 65)
      dir = package(home, long, "name: #{long}\ndescription: Use when needed.")

      {:ok, report} = Validate.run(dir)
      assert severity(report, :name_length) == :error
    end

    test "a name that differs from the directory is an error", %{home: home} do
      dir = package(home, "one", "name: two\ndescription: Use when needed.")

      {:ok, report} = Validate.run(dir)
      assert severity(report, :name_mismatch) == :error
    end

    test "a missing name is an error", %{home: home} do
      dir = package(home, "nameless", "description: Use when needed.")

      {:ok, report} = Validate.run(dir)
      assert severity(report, :name_missing) == :error
    end
  end

  describe "description" do
    test "missing, empty and over 1024 characters are errors", %{home: home} do
      {:ok, missing} = home |> package("a-one", "name: a-one") |> Validate.run()
      assert severity(missing, :description_missing) == :error

      {:ok, empty} = home |> package("a-two", "name: a-two\ndescription: \"\"") |> Validate.run()
      assert severity(empty, :description_missing) == :error

      long = String.duplicate("x", 1025)
      {:ok, too_long} = home |> package("a-three", "name: a-three\ndescription: #{long}") |> Validate.run()
      assert severity(too_long, :description_length) == :error
    end
  end

  describe "optional fields" do
    test "compatibility over 500 characters is an error", %{home: home} do
      header = "name: compat\ndescription: Use when needed.\ncompatibility: #{String.duplicate("x", 501)}"
      {:ok, report} = home |> package("compat", header) |> Validate.run()
      assert severity(report, :compatibility_length) == :error
    end

    test "metadata must be a mapping, and numeric values are a warning", %{home: home} do
      {:ok, not_a_map} = home |> package("meta-one", "name: meta-one\ndescription: Use when needed.\nmetadata: [a, b]") |> Validate.run()
      assert severity(not_a_map, :metadata_type) == :error

      header = "name: meta-two\ndescription: Use when needed.\nmetadata:\n  author: someone\n  version: 1.0"
      {:ok, numeric} = home |> package("meta-two", header) |> Validate.run()
      assert numeric.valid?
      assert severity(numeric, :metadata_values) == :warning
    end

    test "allowed-tools as a list is a warning, as a string is fine", %{home: home} do
      base = "name: tools-one\ndescription: Use when needed."

      {:ok, list} = home |> package("tools-one", base <> "\nallowed-tools: [Read, Bash]") |> Validate.run()
      assert list.valid?
      assert severity(list, :allowed_tools_list) == :warning

      {:ok, string} = home |> package("tools-one", base <> "\nallowed-tools: Bash(git:*) Read") |> Validate.run()
      refute :allowed_tools_list in rules(string)
    end

    test "a license that is not a string is an error", %{home: home} do
      header = "name: lic\ndescription: Use when needed.\nlicense: [MIT]"
      {:ok, report} = home |> package("lic", header) |> Validate.run()
      assert severity(report, :license_type) == :error
    end
  end

  test "an unquoted colon in a value is read but flagged", %{home: home} do
    dir = package(home, "colon", "name: colon\ndescription: Use when: the user sends a PDF")

    {:ok, report} = Validate.run(dir)
    assert report.valid?
    assert severity(report, :header_recovered) == :warning
  end

  test "a package whose entry doc is not SKILL.md is a warning", %{home: home} do
    dir = Path.join([home, "skills", "notes-skill"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "notes-skill.md"), "---\nname: notes-skill\ndescription: Use when noting.\n---\n\nbody\n")

    {:ok, report} = Validate.run(dir)
    assert report.valid?
    assert severity(report, :entry_name) == :warning
  end

  test "a body over 500 lines is a warning", %{home: home} do
    body = Enum.map_join(1..510, "\n", &"line #{&1}")
    dir = package(home, "long-body", "name: long-body\ndescription: Use when needed.", body)

    {:ok, report} = Validate.run(dir)
    assert report.valid?
    assert severity(report, :body_long) == :warning
  end

  test "a skill file given by path is judged by its file name", %{home: home} do
    file = Path.join([home, "skills", "loose.md"])
    File.write!(file, "---\nname: other\ndescription: Use when needed.\n---\n\nbody\n")

    {:ok, report} = Validate.run(file)
    assert severity(report, :name_mismatch) == :error
  end

  test "a SKILL.md given by path stands for its directory", %{home: home} do
    dir = package(home, "by-file", "name: by-file\ndescription: Use when needed.")

    assert {:ok, report} = Validate.run(Path.join(dir, "SKILL.md"))
    assert report.valid?
  end

  test "an installed skill can be validated by name, and an unknown target is not found", %{home: home} do
    package(home, "known-skill", "name: known-skill\ndescription: Use when needed.")

    assert {:ok, %{valid?: true}} = Validate.run("known-skill")
    assert {:error, :not_found} = Validate.run("no-such-skill-anywhere")
  end

  test "findings/2 checks a text that has no path yet" do
    text = "---\nname: Bad_Name\ndescription: Use when needed.\n---\n\nbody\n"

    assert :name_format in Enum.map(Validate.findings(text), & &1.rule)
  end
end
