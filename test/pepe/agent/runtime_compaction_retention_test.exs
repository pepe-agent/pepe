defmodule Pepe.Agent.RuntimeCompactionRetentionTest do
  @moduledoc """
  When the running history is large enough that compaction fires mid-turn, the loop must still
  RETURN the full, uncompacted history plus the new turn - never the shrunken list it sent to the
  model. The caller (Session.spawn_run) recovers this turn's new messages by dropping the prior
  history by length; if the returned list were compacted, that drop would eat into the turn and
  silently lose it (and re-summarize on every subsequent turn). This is the regression guard.
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Pepe.Agent.Runtime
  alias Pepe.Config.Agent
  alias Pepe.Config.Model
  alias Pepe.LLM.Message

  # Answers every call - both the summarizer call compaction makes and the main turn - with a fixed,
  # final assistant reply (no tool calls), so the loop terminates in one iteration.
  defmodule AnswerPlug do
    @moduledoc false
    import Plug.Conn

    def init(o), do: o

    def call(conn, _) do
      {:ok, _body, conn} = read_body(conn)

      payload = %{
        "choices" => [
          %{"index" => 0, "message" => %{"role" => "assistant", "content" => "done"}, "finish_reason" => "stop"}
        ]
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  # A tiny context window forces compaction on the history below without a huge fixture.
  defp mock_model do
    server = start_supervised!({Bandit, plug: AnswerPlug, port: 0, scheme: :http})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    %Model{name: "m", base_url: "http://localhost:#{port}", api_key: "test", model: "id", context_window: 100}
  end

  # Six messages, each big enough that only the last fits the verbatim tail: over the threshold, so
  # compaction condenses head + summary + tail (fewer than six) for the model call.
  defp long_history do
    [
      Message.system("You are helpful."),
      Message.user("q1 " <> String.duplicate("a", 100)),
      Message.assistant("a1 " <> String.duplicate("b", 100)),
      Message.user("q2 " <> String.duplicate("c", 100)),
      Message.assistant("a2 " <> String.duplicate("d", 100)),
      Message.user("q3 " <> String.duplicate("e", 100))
    ]
  end

  test "the returned history keeps every input message plus the reply, even when compaction fires" do
    model = mock_model()
    history = long_history()
    agent = %Agent{name: "eng", system_prompt: "sys", tools: [], max_iterations: 3}

    assert {:ok, "done", all} = Runtime.run(agent, history, model: model)

    # Nothing was compacted away from what we return: the original history is intact at the front...
    assert Enum.take(all, length(history)) == history
    # ...and this turn's reply is appended. (The buggy version returned head+summary+tail+reply, so
    # `Enum.take(all, 6)` would NOT equal the original six.)
    assert List.last(all) == Message.assistant("done")
    assert length(all) == length(history) + 1
  end
end
