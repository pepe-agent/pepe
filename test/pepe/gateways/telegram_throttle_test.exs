defmodule Pepe.Gateways.Telegram.ThrottleTest do
  @moduledoc "Inbound Telegram messages are rate-limited per chat, so anyone who can message the bot can't flood it into unbounded tasks and provider calls."
  use ExUnit.Case, async: false

  alias Pepe.Gateways.Telegram.Throttle

  setup do
    {:ok, _} = Application.ensure_all_started(:pepe)
    prev = Application.get_env(:pepe, :telegram_rate_limit)
    Application.put_env(:pepe, :telegram_rate_limit, 3)

    on_exit(fn ->
      if prev, do: Application.put_env(:pepe, :telegram_rate_limit, prev), else: Application.delete_env(:pepe, :telegram_rate_limit)
    end)

    :ok
  end

  test "a chat is allowed up to its budget, then refused" do
    chat = System.unique_integer([:positive])
    assert Throttle.allow?(chat)
    assert Throttle.allow?(chat)
    assert Throttle.allow?(chat)
    refute Throttle.allow?(chat), "the 4th message past a budget of 3 must be refused"
  end

  test "one chat's flood doesn't spend another chat's budget" do
    a = System.unique_integer([:positive])
    b = System.unique_integer([:positive])
    for _ <- 1..5, do: Throttle.allow?(a)
    # b is a different chat and untouched by a's flood.
    assert Throttle.allow?(b)
  end
end
