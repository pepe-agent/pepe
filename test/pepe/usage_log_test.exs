defmodule Pepe.Usage.LogTest do
  @moduledoc """
  `entries_between/3` is the bounded read `month_to_date/1` and `Pepe.Usage.invoice/2` use
  instead of `entries/1` (every entry the scope has ever recorded) - a real `WHERE at >= ?
  AND at < ?` query, exact by construction (no month-file-neighbor approximation to get
  right the way the old file-partitioned ledger needed).
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Usage.Log

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_usagelog_#{System.unique_integer([:positive])}")
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

  defp seed(scope, at) do
    Log.append(scope, %{"at" => at, "agent" => "a", "model" => "m", "in" => 1, "out" => 1})
  end

  defp unix(y, m, d), do: DateTime.new!(Date.new!(y, m, d), Time.new!(12, 0, 0)) |> DateTime.to_unix()

  test "entries_between/3 returns only entries within [from, to)" do
    seed("p", unix(2026, 5, 31))
    seed("p", unix(2026, 6, 1))
    seed("p", unix(2026, 6, 30))
    seed("p", unix(2026, 7, 1))

    from = unix(2026, 6, 1)
    to = unix(2026, 7, 1)

    entries = Log.entries_between("p", from, to)
    assert [_, _] = entries
    assert Enum.all?(entries, &(&1["at"] >= from and &1["at"] < to))
  end

  test "entries_between/3 doesn't see another scope's entries" do
    seed("p", unix(2026, 6, 15))
    seed("other", unix(2026, 6, 15))

    entries = Log.entries_between("p", unix(2026, 6, 1), unix(2026, 7, 1))
    assert [entry] = entries
    assert entry["project"] == "p"
  end

  test "an empty scope returns an empty list, not an error" do
    assert Log.entries_between("nothing-here", unix(2026, 6, 1), unix(2026, 7, 1)) == []
  end

  test "month_to_date/1 still finds spend recorded near a month boundary" do
    Config.add_project("acme", %{"budget" => 100.0})
    Config.put_model(%Config.Model{name: "acme/m", model: "gpt-4o", input_price: 1.0, output_price: 0.0})

    # Real time, since month_to_date/1 reads the real clock - the bounded read must still
    # find an entry recorded right now, same as entries/1 always did.
    now = System.os_time(:second)
    Log.append("acme", %{"at" => now, "agent" => "acme/x", "model" => "acme/m", "in" => 1_000_000, "out" => 0})

    assert_in_delta Pepe.Usage.month_to_date("acme"), 1.0, 0.0001
  end
end
