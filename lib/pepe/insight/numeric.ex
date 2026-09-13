defmodule Pepe.Insight.Numeric do
  @moduledoc """
  Value-based numeric parsing shared by `Trainer` (fitting) and `Predictor` (inference) -
  intentionally value-based rather than schema-based, since an imported row has no
  `information_schema` to consult: a `"db"` row and an `"import"` row must be parseable by
  exactly the same rule, or the two sources would silently train differently.
  """

  @spec to_number(term()) :: {:ok, float()} | :error
  def to_number(%Decimal{} = d), do: {:ok, Decimal.to_float(d)}
  def to_number(n) when is_number(n), do: {:ok, n * 1.0}
  def to_number(b) when is_boolean(b), do: {:ok, if(b, do: 1.0, else: 0.0)}

  def to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def to_number(_other), do: :error
end
