defmodule Pepe.Usage.LogTest do
  @moduledoc """
  `entries_near/2` is the bounded read `month_to_date/1` uses instead of `entries/1` (every month
  the scope has ever recorded) - it must return the current UTC month plus its immediate neighbors
  (so a billing timezone offset near a month boundary can never lose an entry), stay bounded when a
  scope has years of history, and get month arithmetic right across a year rollover.
  """
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Usage.Log

  setup do
    home = Path.join(System.tmp_dir!(), "pepe_usagelog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev = System.get_env("PEPE_HOME")
    System.put_env("PEPE_HOME", home)

    on_exit(fn ->
      if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  # Directly write a ledger line into `YYYY-MM.jsonl`, bypassing append/1's own month-partitioning
  # (which is exactly what's under test) - so a fixture can plant an entry in any month, including
  # ones append/1 would never write "now".
  defp seed_month(scope, year, month, at) do
    dir = Log.scope_dir(scope)
    File.mkdir_p!(dir)
    file = :io_lib.format("~4..0B-~2..0B.jsonl", [year, month]) |> to_string()
    line = Jason.encode!(%{"at" => at, "agent" => "a", "model" => "m", "in" => 1, "out" => 1}) <> "\n"
    File.write!(Path.join(dir, file), line, [:append])
  end

  defp unix(y, m, d), do: DateTime.new!(Date.new!(y, m, d), Time.new!(12, 0, 0)) |> DateTime.to_unix()

  test "returns the current month plus its immediate neighbors, nothing further" do
    now = unix(2026, 6, 15)
    seed_month("p", 2026, 5, unix(2026, 5, 20))
    seed_month("p", 2026, 6, unix(2026, 6, 10))
    seed_month("p", 2026, 7, unix(2026, 7, 5))
    # far outside the 3-month window - must NOT be read
    seed_month("p", 2026, 1, unix(2026, 1, 1))
    seed_month("p", 2025, 12, unix(2025, 12, 1))

    entries = Log.entries_near("p", now)
    assert [_, _, _] = entries
    assert Enum.all?(entries, &(&1["in"] == 1))
  end

  test "a scope's whole history within 3 months matches entries/1 exactly" do
    now = unix(2026, 6, 15)
    seed_month("p", 2026, 6, unix(2026, 6, 1))
    seed_month("p", 2026, 6, unix(2026, 6, 20))

    assert Enum.sort_by(Log.entries_near("p", now), & &1["at"]) ==
             Enum.sort_by(Log.entries("p"), & &1["at"])
  end

  test "December -> January and January -> December roll the year correctly" do
    dec_now = unix(2025, 12, 15)
    seed_month("p", 2025, 11, unix(2025, 11, 1))
    seed_month("p", 2025, 12, unix(2025, 12, 1))
    seed_month("p", 2026, 1, unix(2026, 1, 1))
    # outside the window from December's point of view
    seed_month("p", 2025, 10, unix(2025, 10, 1))

    assert [_, _, _] = Log.entries_near("p", dec_now)

    jan_now = unix(2026, 1, 15)
    # (2026, 1) and (2025, 12) already seeded above; add (2026, 2) to complete January's window
    seed_month("p", 2026, 2, unix(2026, 2, 1))

    assert [_, _, _] = Log.entries_near("p", jan_now)
  end

  test "an empty scope returns an empty list, not an error" do
    assert Log.entries_near("nothing-here", unix(2026, 6, 15)) == []
  end

  test "month_to_date/1 still finds spend recorded near a month boundary" do
    Config.add_project("acme", %{"budget" => 100.0})
    Config.put_model(%Config.Model{name: "acme/m", model: "gpt-4o", input_price: 1.0, output_price: 0.0})

    # Seed directly at "now" (real time, since month_to_date/1 reads the real clock) so this
    # doesn't need to fake System.os_time - the bounded read must still find it, same as entries/1.
    now = System.os_time(:second)
    dir = Log.scope_dir("acme")
    File.mkdir_p!(dir)

    {{y, mo, _d}, _} = :calendar.system_time_to_universal_time(now, :second)
    file = :io_lib.format("~4..0B-~2..0B.jsonl", [y, mo]) |> to_string()
    line = Jason.encode!(%{"at" => now, "agent" => "acme/x", "model" => "acme/m", "in" => 1_000_000, "out" => 0}) <> "\n"
    File.write!(Path.join(dir, file), line, [:append])

    assert_in_delta Pepe.Usage.month_to_date("acme"), 1.0, 0.0001
  end
end
