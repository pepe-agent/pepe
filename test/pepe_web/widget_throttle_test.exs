defmodule PepeWeb.WidgetThrottleTest do
  use ExUnit.Case, async: false

  alias PepeWeb.WidgetThrottle

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)

    prev_limit = Application.get_env(:pepe, :widget_rate_limit)
    prev_window = Application.get_env(:pepe, :widget_rate_window_s)
    Application.put_env(:pepe, :widget_rate_limit, 2)
    Application.put_env(:pepe, :widget_rate_window_s, 60)

    on_exit(fn ->
      if prev_limit, do: Application.put_env(:pepe, :widget_rate_limit, prev_limit), else: Application.delete_env(:pepe, :widget_rate_limit)

      if prev_window,
        do: Application.put_env(:pepe, :widget_rate_window_s, prev_window),
        else: Application.delete_env(:pepe, :widget_rate_window_s)
    end)

    :ok
  end

  test "allows up to the configured limit, then denies" do
    key = "widget-key-#{System.unique_integer([:positive])}"

    assert :ok = WidgetThrottle.check(key)
    assert :ok = WidgetThrottle.check(key)
    assert {:error, retry_ms} = WidgetThrottle.check(key)
    assert retry_ms > 0
  end

  test "different keys have independent budgets" do
    a = "widget-key-a-#{System.unique_integer([:positive])}"
    b = "widget-key-b-#{System.unique_integer([:positive])}"

    assert :ok = WidgetThrottle.check(a)
    assert :ok = WidgetThrottle.check(a)
    assert {:error, _} = WidgetThrottle.check(a)

    # b's budget is untouched by a's usage.
    assert :ok = WidgetThrottle.check(b)
  end
end
