defmodule Pepe.Webhooks.FinishTest do
  @moduledoc """
  What the person on a chat channel hears when their message's run ends. A message the platform
  showed as seen must never end in silence: a failed run and a run with nothing to say both
  answer, and a normal reply is passed through untouched.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pepe.Webhooks

  defmodule FakeProvider do
    @moduledoc false
    def name, do: "fake"

    def deliver(_entry, to, text) do
      send(Process.whereis(:finish_test), {:delivered, to, text})
      :ok
    end
  end

  setup do
    Process.register(self(), :finish_test)
    :ok
  end

  defp job, do: %{entry: %{"slug" => "t"}, mod: FakeProvider, message: %{from: "C1"}}

  test "a normal reply is delivered as it is" do
    Webhooks.finish(job(), {:ok, "all done"})
    assert_receive {:delivered, "C1", "all done"}
  end

  test "a failed run still answers, and keeps the reason out of the chat" do
    log =
      capture_log(fn ->
        Webhooks.finish(job(), {:error, {:http_error, 500, "secret-internal-detail"}})
      end)

    assert_receive {:delivered, "C1", text}
    assert text =~ "could not finish"
    refute text =~ "secret-internal-detail"
    assert log =~ "run failed"
  end

  test "a reply that is only whitespace says the run finished instead of sending nothing" do
    Webhooks.finish(job(), {:ok, "  \n "})
    assert_receive {:delivered, "C1", text}
    assert text =~ "nothing to show"
  end

  test "a missing reply is treated the same way" do
    Webhooks.finish(job(), {:ok, nil})
    assert_receive {:delivered, "C1", text}
    assert text =~ "nothing to show"
  end

  test "a message that arrived while a run was busy is not answered twice" do
    Webhooks.finish(job(), {:error, :busy})
    refute_receive {:delivered, _, _}, 100
  end
end
