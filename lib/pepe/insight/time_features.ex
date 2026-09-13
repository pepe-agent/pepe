defmodule Pepe.Insight.TimeFeatures do
  @moduledoc """
  Turns a timestamp into the fixed set of numeric features `"forecast"` specs train on:
  elapsed time since the spec's own reference point (`"epoch"`, the earliest timestamp
  seen in the training set) plus cyclical day-of-week/month-of-year encodings (sine+cosine
  pairs, so e.g. Sunday and Monday read as close together, not as far apart as 1 and 7
  would), so a plain regression model can pick up a weekly/yearly pattern without treating
  every distinct date as an unrelated category. No exposed configuration - same "Pepe
  decides" philosophy as everywhere else in `Pepe.Insight`.

  `Pepe.Insight.Trainer.fit_forecast/3` and `Pepe.Insight.Predictor`'s forecast path both
  call `features/2`; keeping the derivation in one place is what keeps train-time and
  predict-time features from silently drifting apart.

  Known limitation: a bare `NaiveDateTime` (what Postgrex hands back for a `timestamp
  without time zone` column) is treated as UTC (`parse/1`'s `DateTime.from_naive!/2`
  clause), while a `predict` call's ISO8601 string with an explicit offset is normalized to
  UTC by `DateTime.from_iso8601/1` - if the two inputs actually represent different wall-clock
  zones, day-of-week/elapsed-time features can be off by hours right where a daily forecast
  is most sensitive to it (near midnight). No spec-level timezone field exists yet to correct
  this; an operator training a "forecast" spec off a `timestamp without time zone` column
  should keep both training data and `predict` inputs in the same assumed zone.
  """

  @day_seconds 86_400
  @synthetic_names ~w(__elapsed_days__ __dow_sin__ __dow_cos__ __month_sin__ __month_cos__)

  @doc "The fixed synthetic feature names `features/2` produces, in order - used to size a neural model's input layer correctly."
  @spec synthetic_names() :: [String.t()]
  def synthetic_names, do: @synthetic_names

  @doc "Parse a DateTime/NaiveDateTime/Date/ISO8601 string/Unix-seconds integer into a DateTime, or :error."
  @spec parse(term()) :: {:ok, DateTime.t()} | :error
  def parse(%DateTime{} = dt), do: {:ok, dt}
  def parse(%NaiveDateTime{} = ndt), do: {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  def parse(%Date{} = d), do: {:ok, DateTime.new!(d, ~T[00:00:00])}
  # A row from import_rows/db_query is arbitrary caller data - from_unix!/1 would raise
  # ArgumentError on an out-of-range integer instead of returning :error like every other
  # unparseable value here does.
  def parse(n) when is_integer(n) do
    case DateTime.from_unix(n) do
      {:ok, dt} -> {:ok, dt}
      {:error, _reason} -> :error
    end
  end

  def parse(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> parse_date_only(s)
    end
  end

  def parse(_other), do: :error

  defp parse_date_only(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00])}
      _ -> :error
    end
  end

  @doc "The 5 numeric features for `dt`, relative to `epoch` - same order as `synthetic_names/0`."
  @spec features(DateTime.t(), DateTime.t()) :: [float()]
  def features(%DateTime{} = dt, %DateTime{} = epoch) do
    elapsed_days = DateTime.diff(dt, epoch, :second) / @day_seconds
    dow_angle = (Date.day_of_week(dt) - 1) / 7 * 2 * :math.pi()
    month_angle = (dt.month - 1) / 12 * 2 * :math.pi()

    [elapsed_days * 1.0, :math.sin(dow_angle), :math.cos(dow_angle), :math.sin(month_angle), :math.cos(month_angle)]
  end
end
