defmodule Pepe.Insight.SourceTest do
  @moduledoc """
  The `"import"` branch of `fetch/3` and `row_count/2` - backed by real `Pepe.Repo` SQLite
  via `Pepe.RepoSetup`. The `"db"` branch needs a real Postgres and is exercised by manual
  verification instead, same gap `test/pepe/tools/db_query_test.exs` already documents.
  """

  use ExUnit.Case, async: false

  alias Pepe.Insight.Examples
  alias Pepe.Insight.Source
  alias Pepe.Insight.Spec

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_insight_source_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)
    Pepe.RepoSetup.start!()

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "row_count/2 and fetch/3 read back imported examples shaped like a fetched db row" do
    spec = %Spec{id: "spec1", agent: "clinic", source_kind: "import", target_column: "outcome", feature_columns: ["x"]}
    assert {:ok, _} = Examples.import(spec, [%{"x" => 1, "outcome" => "yes"}, %{"x" => 2, "outcome" => "no"}])

    assert {:ok, 2} = Source.row_count(spec, %{})
    assert {:ok, rows} = Source.fetch(spec, %{})
    assert Enum.sort(rows) == Enum.sort([%{"x" => 1, "outcome" => "yes"}, %{"x" => 2, "outcome" => "no"}])
  end

  test "row_count/2 is 0 for a spec with no imported examples yet" do
    spec = %Spec{id: "spec2", agent: "clinic", source_kind: "import", target_column: "outcome", feature_columns: ["x"]}
    assert {:ok, 0} = Source.row_count(spec, %{})
    assert {:ok, []} = Source.fetch(spec, %{})
  end
end
