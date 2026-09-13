defmodule Pepe.Insight.TimeFeaturesTest do
  @moduledoc """
  `parse/1`'s acceptance of every shape a timestamp can arrive in (DateTime, NaiveDateTime,
  Date, ISO8601 string, date-only string, Unix seconds) and `features/2`'s numeric output -
  train-time and predict-time both go through this same module, so a bug here would silently
  make forecasts wrong rather than fail loudly.
  """

  use ExUnit.Case, async: true

  alias Pepe.Insight.TimeFeatures

  describe "parse/1" do
    test "accepts a DateTime, NaiveDateTime, and Date" do
      assert {:ok, %DateTime{}} = TimeFeatures.parse(DateTime.utc_now())
      assert {:ok, %DateTime{}} = TimeFeatures.parse(NaiveDateTime.utc_now())
      assert {:ok, %DateTime{}} = TimeFeatures.parse(~D[2026-01-15])
    end

    test "accepts an ISO8601 datetime string and a date-only string" do
      assert {:ok, dt} = TimeFeatures.parse("2026-01-15T10:00:00Z")
      assert dt.year == 2026 and dt.month == 1 and dt.day == 15

      assert {:ok, dt2} = TimeFeatures.parse("2026-01-15")
      assert dt2.year == 2026 and dt2.month == 1 and dt2.day == 15
    end

    test "accepts a Unix-seconds integer" do
      assert {:ok, dt} = TimeFeatures.parse(1_768_000_000)
      assert %DateTime{} = dt
    end

    test "rejects garbage" do
      assert TimeFeatures.parse("not a date") == :error
      assert TimeFeatures.parse(nil) == :error
      assert TimeFeatures.parse(%{}) == :error
    end
  end

  describe "features/2" do
    test "elapsed time is 0 at the epoch itself and grows with distance from it" do
      epoch = ~U[2026-01-01 00:00:00Z]
      [elapsed_at_epoch | _] = TimeFeatures.features(epoch, epoch)
      assert elapsed_at_epoch == 0.0

      later = ~U[2026-01-11 00:00:00Z]
      [elapsed_later | _] = TimeFeatures.features(later, epoch)
      assert_in_delta elapsed_later, 10.0, 0.001
    end

    test "day-of-week and month cyclical features stay within [-1, 1]" do
      epoch = ~U[2026-01-01 00:00:00Z]
      [_elapsed, dow_sin, dow_cos, month_sin, month_cos] = TimeFeatures.features(~U[2026-06-15 00:00:00Z], epoch)

      for v <- [dow_sin, dow_cos, month_sin, month_cos] do
        assert v >= -1.0 and v <= 1.0
      end
    end

    test "synthetic_names/0 has the same length as features/2's output" do
      f = TimeFeatures.features(~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:00Z])
      assert length(TimeFeatures.synthetic_names()) == length(f)
    end
  end
end
